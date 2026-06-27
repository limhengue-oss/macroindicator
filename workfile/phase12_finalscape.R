rm(list=ls())
library(readxl)
library(dplyr)
library(purrr)
library(stringr)
library(tidyr)
library(lubridate)

folder_path <- "C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator/workfile"
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
setwd(folder_path)
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

# ==============================================================================
# 3. โค้ดสร้างคอลัมน์จัดกลุ่ม 3 ระดับ (Clean Name / Base Product / Pric
# ==============================================================================

{
df = cleaned_result

# 3. โค้ดสร้างคอลัมน์จัดกลุ่ม 3 ระดับ (Clean Name / Base Product / Price Type)
df_clean <- df %>%
  mutate(
    PRODUCT_UPPER = str_to_upper(PRODUCT),
    PRODUCT_UPPER = str_squish(PRODUCT_UPPER),
    
    # 1. แฟล็กแยกประเภทราคา
    PRICE_TYPE = case_when(
      str_detect(PRODUCT_UPPER, "LPG-CARS|LPG-LARGE|LPG-SMALL") ~ "Industry",
      str_detect(PRODUCT_UPPER, "INDUSTRY") ~ "Industry",
      str_detect(PRODUCT_UPPER, "COASTAL|CASTAL") ~ "Industry",
      str_detect(PRODUCT_UPPER, "L-DIESEL") ~ "Industry",
      str_detect(PRODUCT_UPPER, "PTT|BCP|BPC|OTHER|OTER") ~ "Brand Specific / Others",
      TRUE ~ "Standard"
    ),
    
    # 2. ปรับชื่อมาตรฐาน (เพิ่มขีดกลางให้ดีเซล 0.05%S และเปลี่ยนคำว่าไม่เกินเป็น < )
    PRODUCT_CLEAN = case_when(
      str_detect(PRODUCT_UPPER, "H-DIESEL\\(ไม่เกิน0.7%S\\)") ~ "H-DIESEL(<0.7%S)",
      PRODUCT_UPPER == "HDIESEL(0.05%S)"              ~ "H-DIESEL(0.05%S)", # เพิ่มขีดกลางตรงนี้
      str_detect(PRODUCT_UPPER, "LPG-CARS")   ~ "LPG (CARS)",
      str_detect(PRODUCT_UPPER, "LPG-LARGE")  ~ "LPG (LARGE)",
      str_detect(PRODUCT_UPPER, "LPG-SMALL")  ~ "LPG (SMALL)",
      str_detect(PRODUCT_UPPER, "LPG")        ~ "LPG (GENERAL)",
      PRODUCT_UPPER %in% c("ULG 95R ; UNL", "ULG95", "ULG") ~ "ULG 95",
      PRODUCT_UPPER == "ULG 91R ; UNL"               ~ "ULG 91",
      PRODUCT_UPPER %in% c("GASOHOL95", "GASOHOL95 E10", "GASOHOL") ~ "GASOHOL 95",
      PRODUCT_UPPER %in% c("GASOHOL91", "GASOHOL 91") ~ "GASOHOL 91",
      str_detect(PRODUCT_UPPER, "COASTAL FISH") | str_detect(PRODUCT_UPPER, "CASTAL FISH") ~ "H-DIESEL (COASTAL FISHING)",
      str_detect(PRODUCT_UPPER, "OTERS") ~ str_replace(PRODUCT_UPPER, "OTERS", "OTHERS"),
      str_detect(PRODUCT_UPPER, "BPC")   ~ str_replace(PRODUCT_UPPER, "BPC", "BCP"),
      PRODUCT_UPPER %in% c("H-DIESEL B20", "H-DIESEL 20") ~ "H-DIESEL B20",
      str_detect(PRODUCT_UPPER, "BIODEISEL") ~ str_replace(PRODUCT_UPPER, "BIODEISEL", "BIODIESEL"),
      str_detect(PRODUCT_UPPER, "^FUEL") ~ str_replace(PRODUCT_UPPER, "^FUEL", "FO "),
      TRUE ~ PRODUCT_UPPER
    ),
    
    # 3. รวบกลุ่มเนื้อผลิตภัณฑ์จริง (Base Product) ให้ 0.7%S และ ไม่เกิน 0.7%S มาเจอกัน
    BASE_PRODUCT = case_when(
      str_detect(PRODUCT_CLEAN, "BIODIESEL \\(B5\\)") ~ "BIODIESEL (B5)",
      str_detect(PRODUCT_CLEAN, "0\\.7%S") ~ "H-DIESEL(<0.7%S)", # มัดรวม 0.7%S ทั้งหมดเข้าด้วยกัน
      str_detect(PRODUCT_CLEAN, "0\\.05%S") ~ "H-DIESEL(0.05%S)",
      str_detect(PRODUCT_CLEAN, "H-DIESEL\\(0\\.035%S\\)") ~ "H-DIESEL(0.035%S)",
      str_detect(PRODUCT_CLEAN, "LPG") ~ "LPG",
      str_detect(PRODUCT_CLEAN, "COASTAL FISHING") ~ "H-DIESEL",
      str_detect(PRODUCT_CLEAN, "FO 600") ~ "FO 600 2%S",
      str_detect(PRODUCT_CLEAN, "FO 1500") ~ "FO 1500 2%S",
      TRUE ~ PRODUCT_CLEAN
    ),
    BASE_PRODUCT = str_to_upper(str_squish(BASE_PRODUCT))
  ) 

# ดูผลลัพธ์เปรียบเทียบ ชื่อเดิม vs ชื่อใหม่
clean_result = df_clean[, c("PRODUCT", "PRODUCT_CLEAN","PRICE_TYPE","BASE_PRODUCT")] %>% unique() %>% arrange(BASE_PRODUCT)

}


# ==============================================================================
# โค้ด R สำหรับกรองเฉพาะกลุ่มน้ำมันเป้าหมายตามชื่อจริงในระบบ (PRODUCT_CLEAN)
# ==============================================================================

# 1. กำหนดลิสต์รายชื่อน้ำมันเป้าหมายตามแกน Y ในระบบจริง
target_products <- c("LPG (GENERAL)", "ULG 95", "GASOHOL95 E85", "GASOHOL95 E20", "GASOHOL 95", "GASOHOL 91", "FO 600 (1) 2%S", "FO 1500 (2) 2%S", "H-DIESEL", "H-DIESEL B7", "H-DIESEL B10", "H-DIESEL B20")

# 2. ทำการ Join และกรองเอาเฉพาะคอลลัมน์โครงสร้างราคาหลักทันที
df_oil_selected <- clean_result %>%
  left_join(df_map, by = "PRODUCT") %>%
  filter(PRODUCT_CLEAN %in% target_products) %>%
  select(DATE, PRODUCT_CLEAN, RETAIL, WHOLESALE, OIL_FUND, EX_REFIN, M_TAX, EXCISE_TAX, MARKETING_MARGIN) %>%
  arrange(PRODUCT_CLEAN, DATE)


# ==============================================================================
# โค้ด R สำหรับ Visualise ช่วงเวลาข้อมูลน้ำมันด้วย ggplot2 (Timeline Coverage)
# ==============================================================================

library(dplyr)
library(ggplot2)
library(scales) # สำหรับช่วยจัดฟอร์แมตแกนวันที่ (เช่น ยื่นเว้นระยะทีละ 1-2 ปี)
{
# [ขั้นตอนที่ 1]: เตรียมข้อมูลสำหรับการพล็อต
# นำตารางรายวันมา Join คัดเอาเฉพาะ Standard Retail และยุบแถวซ้ำออกเพื่อไม่ให้หนักเครื่องตอนพล็อต
df_plot_data <- df_clean

# [ขั้นตอนที่ 2]: สั่งพล็อตกราฟไทม์ไลน์
ggplot(df_plot_data, aes(x = DATE, y = PRODUCT_CLEAN, color = BASE_PRODUCT)) +
  # พล็อตเป็นจุดเม็ดเล็กๆ ตามวันที่ปรากฏจริง (ถ้าช่วงไหนจุดขาดสาย แปลว่าวันนั้นไม่มีข้อมูล)
  geom_point(alpha = 0.5, size = 0.6) + 
  
  # ปรับแกน X (วันที่) ให้แบ่งสเกลทุกๆ 2 ปี และแสดงเป็นตัวเลขปี ค.ศ.
  scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
  
  # ปรับแต่งรายละเอียดความสวยงาม (Theme)
  labs(
    title = "Data Coverage Timeline by PRODUCT_CLEAN",
    subtitle = "จุดแสดงช่วงวันที่มีข้อมูลราคาบันทึกจริงในระบบ (เฉพาะกลุ่ม Standard Retail)",
    x = "ปี (Year)",
    y = "ประเภทน้ำมันมาตรฐาน (PRODUCT_CLEAN)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 14, hjust = 0.5, margin = margin(b=10)),
    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30", margin = margin(b=15)),
    axis.text.y = element_text(size = 9, face = "bold", color = "black"),
    axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
    legend.position = "none",  # ซ่อนกล่องคำอธิบายสี เนื่องจากชื่อน้ำมันเรียงอยู่ที่แกน Y ชัดเจนแล้ว
    panel.grid.major.y = element_line(color = "gray92", linetype = "dashed"), # เส้นไกด์ไลน์แนวนอนอ่านง่ายๆ
    panel.grid.minor = element_blank()
  )
}

# ==============================================================================
# โค้ด R สำหรับพล็อตกราฟราคาดีเซลรายวัน (H-DIESEL, B10, B20) ในชาร์ตเดียวกัน
# ==============================================================================

# [ขั้นตอนที่ 1]: เตรียมและกรองข้อมูลเฉพาะ 3 ผลิตภัณฑ์หลักที่ต้องการพล็อต
df_diesel_plot <- df_clean %>%
  # เลือกเฉพาะราคาขายปลีกมาตรฐาน และกรองเอาเฉพาะ 3 ตัวตามโจทย์
  filter(
    PRODUCT_CLEAN %in% c("H-DIESEL","H-DIESEL B7","H-DIESEL B10", "H-DIESEL B20")
  ) %>%
  # เลือกคอลลัมน์ที่จำเป็นและหาค่าเฉลี่ยเผื่อกรณีมีข้อมูลซ้ำในวันเดียวกัน
  group_by(DATE, PRODUCT_CLEAN) %>%
  summarise(PRICE = mean(RETAIL, na.rm = TRUE), .groups = 'drop')

# [ขั้นตอนที่ 2]: สั่งพล็อตกราฟเส้นรายวัน (Time Series Line Chart)
ggplot(df_diesel_plot, aes(x = DATE, y = PRICE, color = PRODUCT_CLEAN, group = PRODUCT_CLEAN)) +
  # พล็อตเป็นเส้นต่อเนื่องรายวัน
  geom_point(size = 1.2, alpha = 0.85) +
  
  # ตั้งค่าสีแยกแยะแต่ละผลิตภัณฑ์ให้ดูง่ายและชัดเจน
  scale_color_manual(
    values = c(
      "H-DIESEL"     = "#1f77b4",  # สีน้ำเงิน (ดีเซลหลักเกรดเก่า)
      "H-DIESEL B7" =  "#000000",  # สีดำ
      "H-DIESEL B10" = "#ff7f0e",  # สีส้ม
      "H-DIESEL B20" = "#2ca02c"   # สีเขียว
    )
  ) +
  
  # จัดฟอร์แมตแกนวันที่ (X) และแกนราคา (Y)
  scale_x_date(date_breaks = "1 year", date_labels = "%Y") +
  scale_y_continuous(labels = label_comma(suffix = " บาท/ลิตร")) +
  
  # ตกแต่งธีมและองค์ประกอบกราฟให้ Scannable สวยงาม
  labs(
    title = "Daily Price Comparison: H-DIESEL, B10, and B20",
    subtitle = "เปรียบเทียบแนวโน้มราคาน้ำมันดีเซลรายวัน (เฉพาะกลุ่ม Standard Retail)",
    x = "ปี (Year)",
    y = "ราคาขายปลีก (Price)",
    color = "ประเภทดีเซล (Product)"
  ) +
  theme_minimal() +
  theme(
    plot.title = element_text(face = "bold", size = 14, hjust = 0.5, margin = margin(b=8)),
    plot.subtitle = element_text(size = 11, hjust = 0.5, color = "gray30", margin = margin(b=15)),
    axis.text = element_text(size = 10, color = "black"),
    axis.title = element_text(face = "bold", size = 11),
    legend.position = "bottom", # ย้ายกล่องคำอธิบายมาไว้ด้านล่างเพื่อขยายพื้นที่กราฟด้านข้าง
    legend.title = element_text(face = "bold", size = 10),
    legend.text = element_text(size = 10),
    panel.grid.major = element_line(color = "gray93"),
    panel.grid.minor = element_blank()
  )


# ==============================================================================
# โค้ด R สำหรับพล็อต Facet แยกรายผลิตภัณฑ์ (PRODUCT_CLEAN) 
# โดยในแต่ละ Facet จะมีเส้น RETAIL, WHOLESALE และ OIL_FUND รวมอยู่ด้วยกัน
# ==============================================================================

library(dplyr)
library(ggplot2)
library(tidyr)
library(scales)

# [ขั้นตอนที่ 1]: เตรียมข้อมูลและแปลงโครงสร้างให้อยู่ในรูป Long Format
df_facet_multi_lines <- df_clean %>%
  
  # 2. ฟิลเตอร์เจาะจงเฉพาะกลุ่มน้ำมันตามเงื่อนไข PRODUCT_CLEAN
  filter(PRODUCT_CLEAN %in% c("H-DIESEL", "H-DIESEL B7")) %>%
  
  # 3. เลือกคอลลัมน์วันที่, ชื่อน้ำมันมาตรฐาน และคอลลัมน์ราคาทั้ง 3 ตัวที่ต้องการพล็อต
  select(DATE, PRODUCT_CLEAN, RETAIL, WHOLESALE, OIL_FUND) %>%
  
  # 4. ยุบกลุ่มหาค่าเฉลี่ยรายวันเพื่อป้องกันกรณีมีข้อมูลซ้ำซ้อนในวันเดียวกัน
  group_by(DATE, PRODUCT_CLEAN) %>%
  summarise(
    RETAIL    = mean(RETAIL, na.rm = TRUE),
    WHOLESALE = mean(WHOLESALE, na.rm = TRUE),
    OIL_FUND  = mean(OIL_FUND, na.rm = TRUE),
    .groups = 'drop'
  ) %>%
  
  # 5. แปลงคอลลัมน์ราคา/กองทุน ทั้ง 3 ตัวให้แตกเป็นแถวยาวเพื่อแยกสีเส้นใน ggplot
  pivot_longer(
    cols = c(RETAIL, WHOLESALE, OIL_FUND),
    names_to = "COMPONENT_TYPE",
    values_to = "PRICE_VALUE"
  ) %>%
  
  # 6. ปรับชื่อตัวแปรให้อ่านง่ายสำหรับนำไปแสดงผลบน Legend ด้านล่างชาร์ต
  mutate(
    COMPONENT_TYPE = case_when(
      COMPONENT_TYPE == "RETAIL"    ~ "Retail Price (ราคาขายปลีก)",
      COMPONENT_TYPE == "WHOLESALE" ~ "Wholesale Price (ราคาขายส่ง)",
      COMPONENT_TYPE == "OIL_FUND"  ~ "Oil Fund (เงินกองทุนน้ำมัน)"
    )
  )

# [ขั้นตอนที่ 2]: สั่งพล็อตกราฟแยกหน้าต่าง (Facet) ตามชื่อผลิตภัณฑ์
ggplot(df_facet_multi_lines, aes(x = DATE, y = PRICE_VALUE, color = PRODUCT_CLEAN, group = PRODUCT_CLEAN)) +
  # พล็อตเส้นแนวโน้มรายวัน
  geom_point(size = 0.75, alpha = 0.85) +
  
  # แยกหน้าต่าง (Facet) ตามชนิดน้ำมัน (PRODUCT_CLEAN) 
  # โดยปล่อยให้สเกลแกน Y ขยับอิสระเพื่อให้เห็นรายละเอียดชัดเจนทั้งสองฝั่ง
  facet_wrap(~ COMPONENT_TYPE, ncol = 3, scales = "free_y") +
  
  # กำหนดสีเฉพาะเจาะจงให้แต่ละเส้นเพื่อให้สแกนสายตาดูง่าย
  scale_color_manual(
    values = c(
      "H-DIESEL"    = "#1f77b4",  # สีน้ำเงิน
      "H-DIESEL B20"  = "#2ca02c"   # สีเขียว
    )
  ) +
  
  # จัดรูปแบบแกน X วันที่ และแกน Y ตัวเลขราคา
  scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
  scale_y_continuous(labels = label_comma(suffix = " บาท/ลิตร")) +
  
  # ตกแต่งธีมและข้อความอธิบายกราฟ
  labs(
    title = "Oil Price Structure Breakdown by PRODUCT_CLEAN",
    subtitle = "เปรียบเทียบแนวโน้มราคาขายปลีก ขายส่ง และกองทุนน้ำมันรายวันร่วมกันในแต่ละผลิตภัณฑ์",
    x = "ปี (Year)",
    y = "ราคา / อัตราเงินเก็บ (Baht per Liter)",
    color = "ชนิดน้ำมัน"
  ) +
  theme_bw() + # ใช้ธีมกรอบสี่เหลี่ยมเพื่อให้เห็นขอบเขตหน้าต่างของน้ำมันแต่ละตัวชัดเจน
  theme(
    plot.title = element_text(face = "bold", size = 13, hjust = 0.5, margin = margin(b=8)),
    plot.subtitle = element_text(size = 10.5, hjust = 0.5, color = "gray30", margin = margin(b=15)),
    strip.text = element_text(face = "bold", size = 11), # หัวข้อบนกล่อง Facet (H-DIESEL, H-DIESEL B20)
    strip.background = element_rect(fill = "gray95"),
    axis.text.x = element_text(angle = 45, hjust = 1, vjust = 1),
    axis.text.y = element_text(size = 9),
    legend.position = "bottom", # ย้ายคำอธิบายสีเส้นมาไว้ด้านล่างเพื่อประหยัดพื้นที่พล็อตกราฟ
    panel.grid.minor = element_blank()
  )

write.csv(cleaned_result,file='cleaned_result_v2.csv')


ggplot(cleaned_result %>% filter(PRODUCT == 'H-DIESEL'),aes(x=DATE,y=RETAIL))+geom_line()