rm(list=ls())
library(readxl)
library(dplyr)
library(purrr)
library(stringr)
library(tidyr)
library(lubridate)

folder_path <- "C:/Users/wasinr/OneDrive - Bank of Thailand/My Github/MacroIndicator/RetailOil"
file_list <- list.files(path = folder_path, pattern = "\\.xlsx$", full.names = TRUE)
clean_files <- file_list[!str_detect(basename(file_list), "^~")]

if (length(clean_files) == 0) stop("❌ ไม่พบไฟล์")

set.seed(123)
sampled_files <- clean_files

# --- helpers ---

extract_date <- function(cells) {
  cells <- str_trim(cells)
  cells <- cells[!is.na(cells) & cells != ""]
  cells <- cells[!str_detect(cells, "(?i)PRICE|STRUCTURE|โครงสร้าง|ราคาขายปลีก")]
  
  m <- cells[str_detect(cells, "(\\d{1,4}[/-]\\d{1,2}[/-]\\d{2,4})|(\\d{1,2}-[ก-์a-zA-Z\\.]+(-\\d{2,4}))")]
  if (length(m) > 0) return(m[1])
  
  s <- cells[str_detect(cells, "^[34]\\d{4}$")]
  if (length(s) > 0) return(as.character(as.Date(as.numeric(s[1]), origin = "1899-12-30")))
  
  l <- cells[str_detect(cells, "(19\\d{2})|(20\\d{2})|(25\\d{2})")]
  if (length(l) > 0) return(l[1])
  
  NA_character_
}

extract_exrate <- function(df_raw) {
  idx <- which(apply(df_raw, 1, function(row) {
    any(str_detect(row, "(?i)Exchange Rate|อัตราแลกเปลี่ยน"), na.rm = TRUE)
  }))[1]
  if (is.na(idx)) return(NA_character_)
  row_text <- as.character(df_raw[idx, ])
  m <- str_extract(row_text, "\\d{2}\\.\\d+")
  m[!is.na(m)][1]
}

normalize_headers <- function(h) {
  h %>%
    str_replace_all("[\r\n\t]+", " ") %>%
    str_trim() %>%
    str_replace_all("\\s+", " ") %>%
    str_remove_all("\\*") %>%
    str_replace_all("(?i)UNIT\\s*:\\s*BA[HT]{2}/LITRE", "PRODUCT") %>%
    str_replace_all("(?i)EX-REFIN.*", "EX_REFIN") %>%
    str_replace_all("(?i)EXCISE.?TAX", "EXCISE_TAX") %>%
    str_replace_all("(?i)M\\.?\\s*TAX", "M_TAX") %>%
    str_replace_all("(?i)OIL.?FUND|OIL FUND", "OIL") %>%
    str_replace_all("(?i)CONSV\\.?\\s*FUND", "CONSV") %>%
    str_replace_all("(?i)WHOLESALE.*", "WHOLESALE") %>%
    str_replace_all("(?i)WS\\s*&\\s*VAT.*", "WS_VAT") %>%
    str_replace_all("(?i)VAT\\s*\\(WS\\)", "VAT_WS") %>%
    str_replace_all("(?i)VAT\\s*\\(MM\\)", "VAT_MM") %>%
    str_replace_all("(?i)MARKETING.*", "MARKETING_MARGIN") %>%
    str_replace_all("(?i)RETAIL.*", "RETAIL") %>%
    str_replace_all("(?i)DISCOUNT.*", "DISCOUNT")
}

find_header_row <- function(df_raw) {
  idx <- which(apply(df_raw, 1, function(row) {
    any(str_detect(row, "(?i)UNIT|หน่วย|BATH/LITRE|BAHT/LITRE"), na.rm = TRUE)
  }))[1]
  if (is.na(idx)) return(NA_integer_)
  
  for (shift in 0:3) {
    test_idx <- idx + shift
    if (test_idx > nrow(df_raw)) break
    test_row <- as.character(df_raw[test_idx, ])
    if (sum(!is.na(test_row) & str_trim(test_row) != "") > 4) return(test_idx)
  }
  idx
}

# --- scraper หลัก (เวอร์ชันใช้ Force Read Logic ผสานตรรกะดั้งเดิมทั้งหมด) ---
n=0
scrape_file <- function(path) {
  
  tmp <- tempfile()
  file.copy(path, tmp, overwrite = TRUE)
  on.exit(unlink(tmp))
  
  # ผสานตรรกะสลับ Engine ด้วยการตรวจสอบรหัสไบนารี (Force Read Logic)
  df_raw <- tryCatch({
    con <- file(tmp, "rb")
    sig <- readBin(con, what = "raw", n = 4)
    close(con)
    sig_hex <- paste(sig, collapse = " ")
    
    if (sig_hex == "d0 cf 11 e0") {
      read_xls(tmp, col_names = FALSE, col_types = "text", sheet = 1)
    } else if (sig_hex == "50 4b 03 04") {
      read_xlsx(tmp, col_names = FALSE, col_types = "text", sheet = 1)
    } else {
      read_excel(tmp, col_names = FALSE, col_types = "text", sheet = 1)
    }
  }, error = function(e) NULL)
  
  if (is.null(df_raw) || nrow(df_raw) == 0) return(NULL)
  
  top_cells  <- as.character(unlist(df_raw[1:min(5, nrow(df_raw)), ]))
  date_val   <- extract_date(top_cells)
  exrate_val <- extract_exrate(df_raw)
  
  header_row <- find_header_row(df_raw)
  if (is.na(header_row)) return(NULL)
  
  raw_headers <- normalize_headers(as.character(df_raw[header_row, ]))
  
  # บังคับ column แรกเป็น PRODUCT เสมอ (รองรับไฟล์ที่ product name ไม่มี label)
  if (is.na(raw_headers[1]) || str_trim(raw_headers[1]) == "") {
    raw_headers[1] <- "PRODUCT"
  }
  
  valid_cols <- which(!is.na(raw_headers) & str_trim(raw_headers) != "")
  if (length(valid_cols) == 0) return(NULL)
  
  headers <- raw_headers[valid_cols]
  
  # หา column index ของ EX_REFIN
  exrefin_col <- valid_cols[which(headers == "EX_REFIN")]
  if (length(exrefin_col) == 0) return(NULL)
  
  # หา row แรกที่ EX_REFIN เป็นตัวเลข → data_start
  data_start <- NA_integer_
  for (i in seq(header_row + 1, nrow(df_raw))) {
    val <- str_trim(as.character(df_raw[i, exrefin_col]))
    if (!is.na(val) && !is.na(suppressWarnings(as.numeric(val)))) {
      data_start <- i
      break
    }
  }
  if (is.na(data_start)) return(NULL)
  
  # อ่านแถวข้อมูลจาก data_start จนเจอ blank row
  data_rows <- list()
  for (i in seq(data_start, nrow(df_raw))) {
    row <- as.character(df_raw[i, valid_cols])
    if (all(is.na(row) | str_trim(row) == "")) break
    data_rows[[length(data_rows) + 1]] <- row
  }
  
  if (length(data_rows) == 0) return(NULL)
  
  df_data <- as.data.frame(do.call(rbind, data_rows), stringsAsFactors = FALSE)
  colnames(df_data) <- headers
  
  df_data$DATE    <- date_val
  df_data$EX_RATE <- exrate_val
  df_data$FILE    <- basename(path)
  
  df_data
}

# --- รันเพื่ออ่านทุกไฟล์แล้วรวมก้อนเดียว ---

message(paste("⚡ กำลังอ่านไฟล์ทั้งหมดจำนวน:", length(sampled_files), "ไฟล์..."))
results <- map(sampled_files, scrape_file) |>
  keep(\(x) !is.null(x)) |>
  bind_rows()

############################################################################
setwd("C:/Users/wasinr/OneDrive - Bank of Thailand/My Github/MacroIndicator/RetailOil")
# save(results,file = 'results.RData')
load('results.RData')
# glimpse(results)
# glimpse(clean_result)

dup_check = results %>% select(DATE,PRODUCT) %>% duplicated()
clean_result = results[!dup_check,]
{# check_no_duplicates = function(df,date_col, product_col,...) {
#   field = c(...)
#   use_df = df[,c(date_col, product_col,field )]
#   dup_keys <- use_df |>
#     group_by(across(all_of(c(date_col, product_col)))) %>% summarise(across(all_of(fields), \(x) sum(!is.na(x))), .groups = "drop")
#   dup_keys2 = dup_keys  %>% select(-date_col, -product_col) 
#   dup_keys2$check = rowSums(dup_keys2)
#   dup_keys$check = dup_keys2$check
#   dup_keys = dup_keys %>% filter(check>1) 
#   if (nrow(dup_keys) > 0) {
#     printed = df[,c(date_col, product_col,'FILE',field )] %>% semi_join(dup_keys,by = date_col) %>% arrange(date_col,product_col)
#     print(head(printed,n=20))
#     stop("❌ พบข้อมูลซ้ำในวันเดียวกัน")
#   }
}

check_no_duplicates <- function(df, date_col, product_col, ...) {
  fields <- c(...)
  
  cleaned <- df |>
    mutate(across(all_of(fields), \(x) na_if(x, "NA")))
  
  dup_keys <- cleaned |>
    filter(if_any(all_of(fields), \(x) !is.na(x))) |>
    group_by(across(all_of(c(date_col, product_col)))) |>
    summarise(across(all_of(fields), \(x) sum(!is.na(x))), .groups = "drop") |>
    filter(if_any(all_of(fields), \(x) x > 1)) |>
    select(all_of(c(date_col, product_col)))
  
  if (nrow(dup_keys) > 0) {
    dup_rows <- cleaned |>
      semi_join(dup_keys, by = c(date_col, product_col)) |>
      select(all_of(c(date_col, product_col, fields)))
    print(dup_rows)
    stop("❌ พบข้อมูลซ้ำในวันเดียวกัน")
  }
  
  message("✅ ผ่าน: ทุก field มีค่าเดียวต่อ date+product")
  invisible(df)
}

check_no_duplicates(df = clean_result,date_col = "DATE",product_col = "PRODUCT","TAX","EXCISE_TAX")

check_no_duplicates(clean_result,date_col = "DATE",product_col = "PRODUCT","VAT","VAT...8","VAT...9","VAT_WS")

check_no_duplicates(clean_result,date_col = "DATE",product_col = "PRODUCT","VAT...11","VAT...12","VAT_MM")

check_no_duplicates(clean_result,date_col = "DATE",product_col = "PRODUCT","CONSV.","CONSV")

check_no_duplicates(clean_result,date_col = "DATE",product_col = "PRODUCT","OIL...5","OIL")

clean_result <- clean_result |>  mutate(EXCISE_TAX = coalesce(na_if(EXCISE_TAX, "NA"), na_if(TAX, "NA"))) |> select(-TAX)

clean_result <- clean_result |>  mutate(VAT_WS = coalesce(na_if(VAT_WS, "NA"), na_if(VAT...8, "NA"))) %>%
  mutate(VAT_WS = coalesce(na_if(VAT_WS, "NA"), na_if(VAT, "NA"))) %>% 
  mutate(VAT_WS = coalesce(na_if(VAT_WS, "NA"), na_if(VAT...9, "NA"))) %>% select(-VAT...8,-VAT...9,-VAT)

clean_result <- clean_result |>  mutate(VAT_MM = coalesce(na_if(VAT_MM, "NA"), na_if(VAT...11, "NA"))) %>% 
  mutate(VAT_MM = coalesce(na_if(VAT_MM, "NA"), na_if(VAT...12, "NA"))) %>% select(-VAT...11,-VAT...12)

clean_result <- clean_result |>  mutate(CONSV = coalesce(na_if(CONSV, "NA"), na_if(CONSV., "NA"))) |> select(-CONSV.)

clean_result <- clean_result |>  mutate(OIL_FUND = coalesce(na_if(OIL, "NA"), na_if(OIL...5, "NA"))) |> select(-OIL,-OIL...5)

clean_result <- clean_result |>  mutate(OIL_FUND_2 = OIL...6) |> select(-OIL...6)

clean_result <- clean_result |>  mutate(CONSV_FUND = CONSV) |> select(-CONSV)

glimpse(clean_result)

clean_result2 <- clean_result %>% select(DATE,PRODUCT,EX_REFIN,EXCISE_TAX,M_TAX,OIL_FUND,CONSV_FUND,WHOLESALE,VAT_WS,WS_VAT,MARKETING_MARGIN,VAT_MM,RETAIL,EX_RATE,FILE,DISCOUNT,OIL_FUND_2)

clean_result2 <- clean_result2 |> mutate(across(-c(DATE, PRODUCT, FILE), as.numeric))

standardize_date <- function(date_vec) {
  d <- as.character(date_vec)
  
  # เพิ่ม "b d, Y" เข้าไปใน orders เพื่อรองรับ "NOV 30 ,2006"
  # นอกจากนี้เพิ่มการลบช่องว่างหน้าคอมมา (ถ้ามี) ด้วย str_replace
  d <- str_replace(d, "\\s*,", ",") 
  
  standardized <- parse_date_time(d, orders = c(
    "d b y",    # 20 JUNE 2007
    "Y-m-d",    # 2004-09-07
    "d B Y",    # 20 June 2007
    "b d, Y",   # NOV 30, 2006
    "d/m/y"     # 07/09/2004
  ))
  
  return(as.Date(standardized))
}

cleaned_result <- clean_result2 |>  mutate(DATE = standardize_date(DATE)) %>%  filter(!is.na(DATE)) %>% arrange(DATE)

write.csv(cleaned_result,file='cleaned_result_v2.csv')
library(ggplot2)

ggplot(cleaned_result %>% filter(PRODUCT == 'H-DIESEL'),aes(x=DATE,y=RETAIL))+geom_line()