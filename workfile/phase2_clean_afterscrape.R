rm(list=ls())
library(readxl)
library(dplyr)
library(purrr)
library(stringr)
library(tidyr)
library(lubridate)
library(ggplot2)
library(scales)

folder_path <- "C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator/workfile"
setwd(folder_path)
load('phase1_results.RData')

# 1. ลบรายการซ้ำ และสร้างฟังก์ชันเช็คค่าซ้ำในกลุ่ม Field
clean_result <- results[!results %>% select(DATE, PRODUCT) %>% duplicated(), ]

check_no_duplicates <- function(df, date_col, product_col, ...) {
  fields <- c(...)
  cleaned <- df |> mutate(across(all_of(fields), \(x) na_if(x, "NA")))
  
  dup_keys <- cleaned |>
    filter(if_any(all_of(fields), \(x) !is.na(x))) |>
    group_by(across(all_of(c(date_col, product_col)))) |>
    summarise(across(all_of(fields), \(x) sum(!is.na(x))), .groups = "drop") |>
    filter(if_any(all_of(fields), \(x) x > 1)) |>
    select(all_of(c(date_col, product_col)))
  
  if (nrow(dup_keys) > 0) {
    print(cleaned |> semi_join(dup_keys, by = c(date_col, product_col)) |> select(all_of(c(date_col, product_col, fields))))
    stop("❌ พบข้อมูลซ้ำในวันเดียวกัน")
  }
  message("✅ ผ่าน: ทุก field มีค่าเดียวต่อ date+product")
  invisible(df)
}

# Run Checks
check_no_duplicates(clean_result, "DATE", "PRODUCT", "TAX", "EXCISE_TAX")
check_no_duplicates(clean_result, "DATE", "PRODUCT", "VAT", "VAT...8", "VAT...9", "VAT_WS")
check_no_duplicates(clean_result, "DATE", "PRODUCT", "VAT...11", "VAT...12", "VAT_MM")
check_no_duplicates(clean_result, "DATE", "PRODUCT", "CONSV.", "CONSV")
check_no_duplicates(clean_result, "DATE", "PRODUCT", "OIL...5", "OIL")

# 2. ยุบรวมคอลัมน์ (Coalesce) และแปลงประเภทข้อมูล
clean_result2 <- clean_result |> 
  mutate(
    EXCISE_TAX = coalesce(na_if(EXCISE_TAX, "NA"), na_if(TAX, "NA")),
    VAT_WS = coalesce(na_if(VAT_WS, "NA"), na_if(VAT...8, "NA"), na_if(VAT, "NA"), na_if(VAT...9, "NA")),
    VAT_MM = coalesce(na_if(VAT_MM, "NA"), na_if(VAT...11, "NA"), na_if(VAT...12, "NA")),
    CONSV_FUND = coalesce(na_if(CONSV, "NA"), na_if(CONSV., "NA")),
    OIL_FUND = coalesce(na_if(OIL, "NA"), na_if(OIL...5, "NA")),
    OIL_FUND_2 = OIL...6
  ) |> 
  select(DATE, PRODUCT, EX_REFIN, EXCISE_TAX, M_TAX, OIL_FUND, CONSV_FUND, WHOLESALE, VAT_WS, WS_VAT, MARKETING_MARGIN, VAT_MM, RETAIL, EX_RATE, FILE, DISCOUNT, OIL_FUND_2) |> 
  mutate(across(-c(DATE, PRODUCT, FILE), as.numeric))

# 3. จัดการ Format วันที่
standardize_date <- function(date_vec) {
  d <- str_replace(as.character(date_vec), "\\s*,", ",") 
  standardized <- parse_date_time(d, orders = c("d b y", "Y-m-d", "d B Y", "b d, Y", "d/m/y"))
  return(as.Date(standardized))
}

cleaned_result <- clean_result2 |> 
  mutate(DATE = standardize_date(DATE)) |> 
  filter(!is.na(DATE)) |> 
  arrange(DATE)

# 4. จัดกลุ่ม 3 ระดับ (Price Type / Clean Name / Base Product)
cleaned_result <- cleaned_result |> 
  mutate(
    PRODUCT_UPPER = str_squish(str_to_upper(PRODUCT)),
    
    PRICE_TYPE = case_when(
      str_detect(PRODUCT_UPPER, "LPG-CARS|LPG-LARGE|LPG-SMALL|INDUSTRY|COASTAL|CASTAL|L-DIESEL") ~ "Industry",
      str_detect(PRODUCT_UPPER, "PTT|BCP|BPC|OTHER|OTER") ~ "Brand Specific / Others",
      TRUE ~ "Standard"
    ),
    
    PRODUCT_CLEAN = case_when(
      str_detect(PRODUCT_UPPER, "H-DIESEL\\(ไม่เกิน0.7%S\\)") ~ "H-DIESEL(<0.7%S)",
      PRODUCT_UPPER == "HDIESEL(0.05%S)"                     ~ "H-DIESEL(0.05%S)",
      str_detect(PRODUCT_UPPER, "LPG-CARS")                   ~ "LPG (CARS)",
      str_detect(PRODUCT_UPPER, "LPG-LARGE")                  ~ "LPG (LARGE)",
      str_detect(PRODUCT_UPPER, "LPG-SMALL")                  ~ "LPG (SMALL)",
      str_detect(PRODUCT_UPPER, "LPG")                        ~ "LPG",
      PRODUCT_UPPER %in% c("ULG 95R ; UNL", "ULG95", "ULG")   ~ "ULG 95",
      PRODUCT_UPPER == "ULG 91R ; UNL"                        ~ "ULG 91",
      PRODUCT_UPPER %in% c("GASOHOL95", "GASOHOL95 E10", "GASOHOL") ~ "GASOHOL 95",
      PRODUCT_UPPER %in% c("GASOHOL91", "GASOHOL 91")         ~ "GASOHOL 91",
      str_detect(PRODUCT_UPPER, "COASTAL FISH|CASTAL FISH")   ~ "H-DIESEL (COASTAL FISHING)",
      str_detect(PRODUCT_UPPER, "OTERS")                      ~ str_replace(PRODUCT_UPPER, "OTERS", "OTHERS"),
      str_detect(PRODUCT_UPPER, "BPC")                        ~ str_replace(PRODUCT_UPPER, "BPC", "BCP"),
      PRODUCT_UPPER %in% c("H-DIESEL B20", "H-DIESEL 20")     ~ "H-DIESEL B20",
      str_detect(PRODUCT_UPPER, "BIODEISEL")                  ~ str_replace(PRODUCT_UPPER, "BIODEISEL", "BIODIESEL"),
      str_detect(PRODUCT_UPPER, "^FUEL")                      ~ str_replace(PRODUCT_UPPER, "^FUEL", "FO "),
      TRUE ~ PRODUCT_UPPER
    ),
    
    BASE_PRODUCT = case_when(
      str_detect(PRODUCT_CLEAN, "BIODIESEL \\(B5\\)") ~ "BIODIESEL (B5)",
      str_detect(PRODUCT_CLEAN, "0\\.7%S")            ~ "H-DIESEL(<0.7%S)",
      str_detect(PRODUCT_CLEAN, "0\\.05%S")           ~ "H-DIESEL(0.05%S)",
      str_detect(PRODUCT_CLEAN, "H-DIESEL\\(0\\.035%S\\)") ~ "H-DIESEL(0.035%S)",
      str_detect(PRODUCT_CLEAN, "LPG")                ~ "LPG",
      str_detect(PRODUCT_CLEAN, "COASTAL FISHING")    ~ "H-DIESEL",
      str_detect(PRODUCT_CLEAN, "FO 600")             ~ "FO 600",
      str_detect(PRODUCT_CLEAN, "FO 1500")            ~ "FO 1500",
      TRUE ~ PRODUCT_CLEAN
    ),
    BASE_PRODUCT = str_to_upper(str_squish(BASE_PRODUCT))
  )

# ฟังก์ชันรวม Product โดยให้ Priority กับตัวที่ต้องการ (ตัวแรก)
union_base_product <- function(df, target_base, priority_base, new_base_name) {
  # แยกข้อมูลเป็น 2 ชุด
  df_priority <- df |> filter(PRODUCT_CLEAN == priority_base)
  df_target   <- df |> filter(PRODUCT_CLEAN == target_base)
  
  # กรองเอา target เฉพาะวันที่ "ไม่มี" ใน priority
  df_target_filtered <- df_target |> 
    anti_join(df_priority, by = "DATE")
  
  # รวมกันและเปลี่ยนชื่อ BASE_PRODUCT
  bind_rows(df_priority, df_target_filtered) |> 
    mutate(BASE_PRODUCT = new_base_name)
}

# --- ใช้งานฟังก์ชันกับกรณีต่างๆ ---
diesel_data <- union_base_product(cleaned_result, "H-DIESEL", "H-DIESEL B7", "DIESEL")
fo1500_data <- union_base_product(cleaned_result, "FO 1500 2%S", "FO 1500 (2) 2%S", "FO 1500")
fo600_data  <- union_base_product(cleaned_result, "FO 600 2%S", "FO 600 (1) 2%S", "FO 600")

# 1. กำหนดลิสต์รายชื่อน้ำมันเป้าหมายตามแกน Y ในระบบจริง
target_products <- c("LPG", "ULG 95", "GASOHOL95 E85", "GASOHOL95 E20", "GASOHOL 95", "GASOHOL 91")

# 2. ทำการ Join และกรองเอาเฉพาะคอลลัมน์โครงสร้างราคาหลักทันที
df_oil_selected <- cleaned_result %>%
  filter(PRODUCT_CLEAN %in% target_products) %>% bind_rows(diesel_data,fo1500_data,fo600_data) %>% 
  select(DATE,BASE_PRODUCT, PRODUCT_CLEAN, EX_REFIN, EXCISE_TAX, M_TAX, OIL_FUND, CONSV_FUND, VAT_WS, MARKETING_MARGIN, VAT_MM, RETAIL, WHOLESALE, EX_RATE) |> 
  arrange(BASE_PRODUCT, DATE)

# ==============================================================================
# โค้ด R สำหรับ Visualise ช่วงเวลาข้อมูลน้ำมันด้วย ggplot2 (Timeline Coverage)
# ==============================================================================
  # นำตารางรายวันมา Join คัดเอาเฉพาะ Standard Retail และยุบแถวซ้ำออกเพื่อไม่ให้หนักเครื่องตอนพล็อต
  df_plot_data <- df_oil_selected
  
  # [ขั้นตอนที่ 2]: สั่งพล็อตกราฟไทม์ไลน์
  ggplot(df_plot_data, aes(x = DATE, y = BASE_PRODUCT, color = BASE_PRODUCT)) +
    # พล็อตเป็นจุดเม็ดเล็กๆ ตามวันที่ปรากฏจริง (ถ้าช่วงไหนจุดขาดสาย แปลว่าวันนั้นไม่มีข้อมูล)
    geom_point(alpha = 0.5, size = 0.6) + 
    
    # ปรับแกน X (วันที่) ให้แบ่งสเกลทุกๆ 2 ปี และแสดงเป็นตัวเลขปี ค.ศ.
    scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
    
    # ปรับแต่งรายละเอียดความสวยงาม (Theme)
    labs(
      title = "Data Coverage Timeline by PRODUCT_CLEAN",
      subtitle = "จุดแสดงช่วงวันที่มีข้อมูลราคาบันStandard Retail)",
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


  # พล็อตข้อมูล
  ggplot(df_plot_data, aes(x = DATE, y = WHOLESALE, color = BASE_PRODUCT)) +
    geom_line(linewidth = 0.8) +
    geom_point(size = 1) +
    facet_wrap(~ BASE_PRODUCT, scales = "free_y") + # free_y ช่วยให้เห็นความต่างของราคาแต่ละผลิตภัณฑ์ชัดขึ้น
    theme_minimal() +
    labs(
      title = "Retail Price Trend by Product",
      x = "Date",
      y = "Retail Price",
      color = "Base Product"
    ) +
    theme(legend.position = "none") # ลบ Legend เพราะมีชื่อบอกบนหัว facet อยู่แล้ว
  
  write.csv(df_oil_selected,file = 'eppo_backfill.csv')