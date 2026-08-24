# ══════════════════════════════════════════════════════════════════
#  fetch_nesdc.R
#  ดึง GDP รายไตรมาสจริงจาก NESDC (สภาพัฒน์) ครบทั้ง Demand (Expenditure) /
#  Supply (Production) side และ Nominal (current price) / Real (chain
#  volume measures) → push ขึ้น Firestore
#
#  ที่มา: nesdc.go.th หน้า "all tables" ของแต่ละรอบแถลง QGDP (ไม่ใช่ CKAN
#  catalog — เช็คแล้ว 2026-07-24 ว่าไฟล์ในแคตตาล็อก dataset_17_01 ค้างอยู่
#  Q4/2568 ไม่อัพเดทตามรอบแถลงจริงของ NESDC ที่ออก Q1/2569 ไปแล้วตั้งแต่
#  18 พ.ค. 2569) → โหลดไฟล์ (ผ่าน cookie-based bot-check + WordPress
#  permalink redirect 3 ชั้นของ nesdc.go.th — ไม่มี CAPTCHA/JS challenge)
#  → parse sheet "Table 2" (GDP level, ล้านบาท ราคาปี 2002) และ "Table 2.1"
#  (%YoY)
#
#  ⚠️ ต้องอัพเดท RELEASE_PAGE_URL ด้านล่างทุกไตรมาสเมื่อ NESDC แถลงรอบใหม่ —
#  URL นี้ผูกกับรอบแถลงเฉพาะ (query param p=/ddl= เปลี่ยนทุกไตรมาส) ไม่มี
#  endpoint แบบ "ล่าสุดเสมอ" ให้ดึงอัตโนมัติ (หน้า landing page
#  nesdc.go.th/en/info/quarterly-gross-domestic-product-qgdp-en/ ที่ควรจะ
#  ชี้ไปไฟล์ล่าสุดเป็น JS-rendered ดึง URL จริงด้วย static fetch ไม่ได้)
#  วิธีหา URL รอบใหม่: เปิดหน้า landing page ข้างต้นในเบราว์เซอร์ → หาปุ่ม/
#  ลิงก์ "Download Excel File" ของรอบล่าสุด → copy link address
#
#  โครงสร้างไฟล์ (สำรวจแล้ว 2026-07-24): ทุก sheet มี header 5 แถวแรก
#  จากนั้นข้อมูลสลับกันเป็น [แถวปี, ค่า...] ตามด้วย 4 แถว [Q1..Q4, ค่า...]
#  ของปีนั้น วนซ้ำ — label ปี/ไตรมาสอาจมี suffix r (revised) / p,p1
#  (preliminary) ต้องตัดออกก่อนอ่านตัวเลข — column ที่ใช้ของแต่ละตาราง:
#    Table 1   (Demand, Nominal, level)      คอลัมน์ 2=Private consumption,
#              3=Govt consumption, 4=Gross fixed capital formation,
#              5=Change in inventories, 14=GDP รวม
#    Table 2   (Demand, Real/CVM, level)     คอลัมน์เดียวกับ Table 1
#              (2/3/4/5) แต่ GDP รวมอยู่คอลัมน์ 17 แทน
#    Table 3   คอลัมน์ 26 (Z)  = "Gross Domestic Product (25)"          — Supply, Nominal (level)
#    Table 4   คอลัมน์ 29 (AC) = "Gross Domestic Product (CVM) (28)"    — Supply, Real (level)
#  (ตัวเลข Nominal ของ Demand vs Supply ตรงกันเป๊ะเสมอ เพราะเป็น GDP รวมตัว
#  เดียวกัน แค่มองจากคนละมุม — ใช้ cross-check ความถูกต้องได้ — %YoY ไม่เก็บ
#  แล้ว (ตัดออก 2026-08-24 ตามที่ user ตัดสินใจ) คำนวณจาก level เอาเองฝั่งเว็บ)
#
#  Environment variables ที่ต้องตั้ง:
#    GCP_SA_KEY — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_nesdc.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(stringr)
  library(readxl)
  library(jsonlite)
  library(httr2)
  library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

# ⚠️ อัพเดททุกไตรมาสตามรอบแถลงใหม่ของ NESDC (ดูวิธีหาที่ comment ด้านบน)
# ปัจจุบันชี้ไปรอบ Q2/2569 (แถลง 17 ส.ค. 2569) — URL เดิม (p=110061&ddl=110050,
# รอบ Q1/2569) เจอ 404 2026-08-23 เพราะ NESDC ออกรอบใหม่แล้ว URL เก่าถูกถอด
RELEASE_PAGE_URL <- "https://www.nesdc.go.th/en/?p=47533&ddl=116119"

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (R/firestore.R — ใช้ร่วมกับ fetch_*.R
#  อื่นๆ ทั้งหมด, ดู R/firestore.R สำหรับรายละเอียด)
# ══════════════════════════════════════════════════════════════════
source("R/firestore.R")

# ══════════════════════════════════════════════════════════════════
#  PART 2 — โหลด + parse
# ══════════════════════════════════════════════════════════════════

# RELEASE_PAGE_URL redirect 3 ชั้นกว่าจะถึงไฟล์จริง: (1) cookie-based
# bot-check ของ nesdc.go.th (302 + Set-Cookie แล้วกลับมา URL เดิม) →
# (2) WordPress ?p=&ddl= resolve เป็น permalink slug → (3) permalink
# redirect ไปไฟล์ .xlsx จริงใน wp-content/uploads — cookiejar="" เปิด
# cookie engine ของ curl ให้จำ cookie ตลอด redirect chain ใน request เดียว
download_qgdp_xlsx <- function(url, dest) {
  request(url) |>
    req_options(cookiejar = "", followlocation = TRUE) |>
    req_headers(`User-Agent` = "Mozilla/5.0 (compatible; macroindicator-bot/1.0)") |>
    req_perform(path = dest)
}

# แกะ sheet ที่ layout เป็น [แถวปี][Q1][Q2][Q3][Q4] วนซ้ำ ออกมาเป็น
# tibble(date, value) — value_col นับแบบ 1-indexed ตาม read_excel — skip
# ปกติ 5 แถว (label แถว 5) แต่ Table 13/14 label อยู่แถว 6 (ผังต่างจากตาราง
# อื่นทั้งหมด) ต้องรับ skip แยกได้
parse_qgdp_table <- function(path, sheet, value_col, skip = 5) {
  raw <- read_excel(path, sheet = sheet, col_names = FALSE, skip = skip)
  out <- list()
  current_year <- NA_integer_
  for (i in seq_len(nrow(raw))) {
    label <- as.character(raw[[1]][i])
    if (is.na(label) || label == "") next

    if (str_detect(label, "^\\d{4}")) {
      current_year <- as.integer(str_extract(label, "^\\d{4}"))
      next
    }
    if (str_detect(label, "^Q[1-4]")) {
      if (is.na(current_year)) next
      val <- suppressWarnings(as.numeric(raw[[value_col]][i]))
      if (is.na(val)) next
      q <- as.integer(str_extract(label, "[1-4]"))
      month <- (q - 1) * 3 + 1
      out[[length(out) + 1]] <- tibble(
        date  = as.Date(sprintf("%d-%02d-01", current_year, month)),
        value = val
      )
    }
  }
  if (length(out) == 0) return(tibble(date = as.Date(character()), value = double()))
  bind_rows(out) |> distinct(date, .keep_all = TRUE) |> arrange(date)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Main
# ══════════════════════════════════════════════════════════════════
xlsx_path <- tempfile(fileext = ".xlsx")
message("── Downloading QGDP XLSX from ", RELEASE_PAGE_URL)
download_qgdp_xlsx(RELEASE_PAGE_URL, xlsx_path)

# doc_id, sheet, value_col (1-indexed), fullName, unit, freq/source คงที่ทุกตัว
# ตัด %YoY ออก (NESDC_GDP_YOY/NESDC_GDP_PROD_YOY เดิม) — user ตัดสินใจ
# 2026-08-24 ว่าคำนวณเอาเองจาก level ฝั่งเว็บได้ ไม่ต้องเก็บซ้ำ
# เพิ่มองค์ประกอบย่อยฝั่ง Demand (Table 1 = Nominal, Table 2 = CVM/Real) —
# คอลัมน์ตรวจสอบจาก header จริงของไฟล์ 2026-08-24 (Q2/2569 release):
# col 2 = Private consumption, col 3 = Government consumption,
# col 4 = Gross fixed capital formation, col 5 = Change in inventories
GDP_CATALOG <- tribble(
  ~doc_id,             ~sheet,      ~value_col, ~fullName,                                                          ~unit,
  "NESDC_GDP_NOMINAL",     "Table 1",   14, "Gross Domestic Product — Demand side, Current Prices (Quarterly)",     "Millions of Baht",
  "NESDC_GDP_CVM",         "Table 2",   17, "Gross Domestic Product — Demand side, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_GDP_PROD_NOMINAL","Table 3",   26, "Gross Domestic Product — Supply/Production side, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_GDP_PROD_CVM",    "Table 4",   29, "Gross Domestic Product — Supply/Production side, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_CONS_PRIVATE_NOMINAL",   "Table 1", 2, "Private Final Consumption Expenditure, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_CONS_PRIVATE_CVM",       "Table 2", 2, "Private Final Consumption Expenditure, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_CONS_GOVT_NOMINAL",      "Table 1", 3, "General Government Final Consumption Expenditure, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_CONS_GOVT_CVM",          "Table 2", 3, "General Government Final Consumption Expenditure, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_INVEST_GFCF_NOMINAL",    "Table 1", 4, "Gross Fixed Capital Formation, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_INVEST_GFCF_CVM",        "Table 2", 4, "Gross Fixed Capital Formation, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_INVEST_INVENTORIES_NOMINAL", "Table 1", 5, "Change in Inventories, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_INVEST_INVENTORIES_CVM",     "Table 2", 5, "Change in Inventories, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_EXPORTS_GS_NOMINAL",   "Table 1", 6, "Exports of Goods and Services, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_EXPORTS_GS_CVM",       "Table 2", 6, "Exports of Goods and Services, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_EXPORTS_GOODS_NOMINAL","Table 1", 7, "Exports of Goods, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_EXPORTS_GOODS_CVM",    "Table 2", 7, "Exports of Goods, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_EXPORTS_SERVICES_NOMINAL","Table 1", 8, "Exports of Services, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_EXPORTS_SERVICES_CVM",    "Table 2", 8, "Exports of Services, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_IMPORTS_GS_NOMINAL",   "Table 1", 9, "Imports of Goods and Services, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_IMPORTS_GS_CVM",       "Table 2", 9, "Imports of Goods and Services, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_IMPORTS_GOODS_NOMINAL","Table 1", 10, "Imports of Goods, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_IMPORTS_GOODS_CVM",    "Table 2", 10, "Imports of Goods, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_IMPORTS_SERVICES_NOMINAL","Table 1", 11, "Imports of Services, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_IMPORTS_SERVICES_CVM",    "Table 2", 11, "Imports of Services, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)"
)

# Net exports ไม่มีคอลัมน์ตรงในไฟล์ NESDC — คำนวณเอง (Exports of goods and
# services − Imports of goods and services) จากคอลัมน์ 6/9 ที่ดึงมาแล้วข้างบน
NET_EXPORT_CATALOG <- tribble(
  ~doc_id,              ~sheet, ~exports_col, ~imports_col, ~fullName, ~unit,
  "NESDC_NETEXPORT_NOMINAL", "Table 1", 6, 9, "Net Exports of Goods and Services (Exports minus Imports), Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_NETEXPORT_CVM",     "Table 2", 6, 9, "Net Exports of Goods and Services (Exports minus Imports), Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)"
)

# Supply side (Table 3=Nominal, Table 4=CVM) — headline GDP_PROD_* อยู่ใน
# GDP_CATALOG ข้างบนแล้ว (col 26/29) ชุดนี้เพิ่มระดับ sector หลัก (ไม่ลงราย
# 24 sub-sector ย่อย) ตามที่ user เลือก 2026-08-24: 3-sector (Agri/
# Industrial/Services) + Manufacturing + Construction (มักดูแยกเพราะเป็น
# indicator หลัก) + 6 หมวดใหญ่ใต้ Services (Trade/Transport/Accommodation/
# Info&Comm/Finance/Real Estate)
SUPPLY_CATALOG <- tribble(
  ~doc_id,             ~nom_col, ~cvm_col, ~fullName,
  "NESDC_SUPPLY_AGRI",         3,  3, "Agriculture, Forestry and Fishing",
  "NESDC_SUPPLY_INDUSTRIAL",   5,  5, "Industrial Sector",
  "NESDC_SUPPLY_MANUFACTURING",7,  7, "Manufacturing",
  "NESDC_SUPPLY_SERVICES",    10, 10, "Services Sector",
  "NESDC_SUPPLY_CONSTRUCTION",11, 11, "Construction",
  "NESDC_SUPPLY_TRADE",       12, 12, "Wholesale and Retail Trade, Repair of Vehicles and Personal and Household Goods",
  "NESDC_SUPPLY_TRANSPORT",   13, 13, "Transport and Storage",
  "NESDC_SUPPLY_ACCOMMODATION",14, 14, "Accommodation and Food Service Activities",
  "NESDC_SUPPLY_INFOCOMM",    15, 15, "Information and Communication",
  "NESDC_SUPPLY_FINANCE",     16, 16, "Financial and Insurance Activities",
  "NESDC_SUPPLY_REALESTATE",  17, 17, "Real Estate Activities"
)

# Consumption composition (Table 7=Nominal, Table 8=CVM) — ระดับ COICOP
# หลัก 12 หมวด (ไม่ลงราย sub-item เช่น Bread/Meat/Fish ใต้ Food) ตามที่ user
# เลือก 2026-08-24 ("เอาตัวใหญ่ๆ ไม่เอา detail จนเกินไป")
CONSUMPTION_CATALOG <- tribble(
  ~doc_id,                    ~col, ~fullName,
  "NESDC_CONS_FOOD",             3, "Food and Non-alcoholic Beverages",
  "NESDC_CONS_ALCOHOL_TOBACCO",  15, "Alcoholic Beverages, Tobacco and Narcotic",
  "NESDC_CONS_CLOTHING",         18, "Clothing and Footwear",
  "NESDC_CONS_HOUSING",          21, "Housing, Water, Electricity, Gas and Other Fuels",
  "NESDC_CONS_FURNISHINGS",      24, "Furnishings, Household Equipment and Routine Maintenance of the House",
  "NESDC_CONS_HEALTH",           27, "Health",
  "NESDC_CONS_TRANSPORT",        28, "Transport",
  "NESDC_CONS_COMMUNICATION",    32, "Communication",
  "NESDC_CONS_RECREATION",       33, "Recreation and Culture",
  "NESDC_CONS_EDUCATION",        37, "Education",
  "NESDC_CONS_RESTAURANTS_HOTELS", 38, "Restaurants and Hotels",
  "NESDC_CONS_MISC",             39, "Miscellaneous Goods and Services"
)

# Investment sub-item — จาก 2 ตารางที่ทับซ้อนกันบางส่วน ตามที่ user เตือน
# 2026-08-24 ("ให้ดูดีๆ ... calculate เองได้"):
#  - Table 11 (Nominal) / Table 12 (CVM) = by type of capital goods —
#    เก็บ Construction (total/Private/Public + Dwellings/Non-Dwellings
#    ของแต่ละฝั่ง, ตัด "Others construction"/"Cost of ownership transfer"
#    ที่ย่อยเกิน) + Machinery&Equipment (total + Transport/Other)
#  - Table 13 (Nominal) / Table 14 (CVM) = by institution — เอาเฉพาะที่ไม่
#    ซ้ำกับ Table 11/12: Equipment แยก Private/Public (11/12 ไม่มีแยก) และ
#    GFCF รวมแยก Private/Public — ไม่เอา Construction-Private/Public จาก
#    ตารางนี้ซ้ำ (ตัวเลขเดียวกับ Table 11/12 เป๊ะ)
#  ⚠️ Table 13/14 header อยู่แถว 6 ไม่ใช่แถว 5 เหมือนตารางอื่น (skip=6)
INVEST_1112_CATALOG <- tribble(
  ~doc_id,                              ~col, ~fullName,
  "NESDC_INVEST_CONSTRUCTION",             2, "Construction (Gross Fixed Capital Formation)",
  "NESDC_INVEST_CONSTRUCTION_PRIVATE",     3, "Construction — Private",
  "NESDC_INVEST_CONSTRUCTION_PRIVATE_DWELLINGS", 4, "Construction — Private, Dwellings",
  "NESDC_INVEST_CONSTRUCTION_PRIVATE_NONDWELLINGS", 5, "Construction — Private, Non-Dwellings",
  "NESDC_INVEST_CONSTRUCTION_PUBLIC",      8, "Construction — Public",
  "NESDC_INVEST_CONSTRUCTION_PUBLIC_DWELLINGS", 9, "Construction — Public, Dwellings",
  "NESDC_INVEST_CONSTRUCTION_PUBLIC_NONDWELLINGS", 10, "Construction — Public, Non-Dwellings",
  "NESDC_INVEST_MACHINERY",                12, "Machinery and Equipment (Gross Fixed Capital Formation)",
  "NESDC_INVEST_MACHINERY_TRANSPORT",      13, "Machinery and Equipment — Transport Equipment",
  "NESDC_INVEST_MACHINERY_OTHER",          14, "Machinery and Equipment — Other Machinery and Equipment"
)
INVEST_1314_CATALOG <- tribble(
  ~doc_id,                    ~col, ~fullName,
  "NESDC_INVEST_EQUIPMENT_PRIVATE", 6, "Equipment (Gross Fixed Capital Formation) — Private",
  "NESDC_INVEST_EQUIPMENT_PUBLIC",  7, "Equipment (Gross Fixed Capital Formation) — Public",
  "NESDC_INVEST_GFCF_PRIVATE",      9, "Gross Fixed Capital Formation — Private (all types)",
  "NESDC_INVEST_GFCF_PUBLIC",      10, "Gross Fixed Capital Formation — Public (all types)"
)

message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

ok <- 0
for (i in seq_len(nrow(GDP_CATALOG))) {
  row <- GDP_CATALOG[i, ]
  message(sprintf("── Parsing %s (%s, col %d)...", row$doc_id, row$sheet, row$value_col))
  df <- parse_qgdp_table(xlsx_path, row$sheet, row$value_col)
  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no data parsed", row$doc_id))
    next
  }
  message(sprintf("  %d rows (%s → %s)", nrow(df), min(df$date), max(df$date)))
  meta <- list(
    fullName = row$fullName,
    currency = if (row$unit == "Percent") "" else "THB",
    unit     = row$unit,
    freq     = "Quarterly",
    source   = "NESDC (nesdc.go.th) — Quarterly GDP"
  )
  if (push_series(token, row$doc_id, row$fullName, df, is_incremental = TRUE, meta = meta)) ok <- ok + 1
}

for (i in seq_len(nrow(NET_EXPORT_CATALOG))) {
  row <- NET_EXPORT_CATALOG[i, ]
  message(sprintf("── Parsing %s (%s, col %d - col %d)...", row$doc_id, row$sheet, row$exports_col, row$imports_col))
  exports_df <- parse_qgdp_table(xlsx_path, row$sheet, row$exports_col)
  imports_df <- parse_qgdp_table(xlsx_path, row$sheet, row$imports_col)
  df <- exports_df |>
    inner_join(imports_df, by = "date", suffix = c("_exp", "_imp")) |>
    transmute(date, value = value_exp - value_imp)
  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no data parsed", row$doc_id))
    next
  }
  message(sprintf("  %d rows (%s → %s)", nrow(df), min(df$date), max(df$date)))
  meta <- list(
    fullName = row$fullName,
    currency = "THB",
    unit     = row$unit,
    freq     = "Quarterly",
    source   = "NESDC (nesdc.go.th) — Quarterly GDP (derived: Exports − Imports)"
  )
  if (push_series(token, row$doc_id, row$fullName, df, is_incremental = TRUE, meta = meta)) ok <- ok + 1
}

push_pair <- function(doc_id, sheet, col, full_name, unit, source_suffix = "", skip = 5) {
  df <- parse_qgdp_table(xlsx_path, sheet, col, skip = skip)
  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no data parsed", doc_id))
    return(FALSE)
  }
  message(sprintf("  %d rows (%s → %s)", nrow(df), min(df$date), max(df$date)))
  meta <- list(
    fullName = full_name,
    currency = "THB",
    unit     = unit,
    freq     = "Quarterly",
    source   = paste0("NESDC (nesdc.go.th) — Quarterly GDP", source_suffix)
  )
  push_series(token, doc_id, full_name, df, is_incremental = TRUE, meta = meta)
}

for (i in seq_len(nrow(SUPPLY_CATALOG))) {
  row <- SUPPLY_CATALOG[i, ]
  message(sprintf("── Parsing %s_NOMINAL (Table 3, col %d)...", row$doc_id, row$nom_col))
  if (push_pair(paste0(row$doc_id, "_NOMINAL"), "Table 3", row$nom_col,
                paste0(row$fullName, ", Current Prices (Quarterly)"), "Millions of Baht")) ok <- ok + 1
  message(sprintf("── Parsing %s_CVM (Table 4, col %d)...", row$doc_id, row$cvm_col))
  if (push_pair(paste0(row$doc_id, "_CVM"), "Table 4", row$cvm_col,
                paste0(row$fullName, ", Chain Volume Measures (Quarterly)"), "Millions of Baht (2002 base)")) ok <- ok + 1
}

for (i in seq_len(nrow(CONSUMPTION_CATALOG))) {
  row <- CONSUMPTION_CATALOG[i, ]
  message(sprintf("── Parsing %s_NOMINAL (Table 7, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_NOMINAL"), "Table 7", row$col,
                paste0(row$fullName, ", Current Prices (Quarterly)"), "Millions of Baht")) ok <- ok + 1
  message(sprintf("── Parsing %s_CVM (Table 8, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_CVM"), "Table 8", row$col,
                paste0(row$fullName, ", Chain Volume Measures (Quarterly)"), "Millions of Baht (2002 base)")) ok <- ok + 1
}

for (i in seq_len(nrow(INVEST_1112_CATALOG))) {
  row <- INVEST_1112_CATALOG[i, ]
  message(sprintf("── Parsing %s_NOMINAL (Table 11, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_NOMINAL"), "Table 11", row$col,
                paste0(row$fullName, ", Current Prices (Quarterly)"), "Millions of Baht")) ok <- ok + 1
  message(sprintf("── Parsing %s_CVM (Table 12, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_CVM"), "Table 12", row$col,
                paste0(row$fullName, ", Chain Volume Measures (Quarterly)"), "Millions of Baht (2002 base)")) ok <- ok + 1
}

for (i in seq_len(nrow(INVEST_1314_CATALOG))) {
  row <- INVEST_1314_CATALOG[i, ]
  message(sprintf("── Parsing %s_NOMINAL (Table 13, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_NOMINAL"), "Table 13", row$col,
                paste0(row$fullName, ", Current Prices (Quarterly)"), "Millions of Baht", skip = 6)) ok <- ok + 1
  message(sprintf("── Parsing %s_CVM (Table 14, col %d)...", row$doc_id, row$col))
  if (push_pair(paste0(row$doc_id, "_CVM"), "Table 14", row$col,
                paste0(row$fullName, ", Chain Volume Measures (Quarterly)"), "Millions of Baht (2002 base)", skip = 6)) ok <- ok + 1
}

n_total <- nrow(GDP_CATALOG) + nrow(NET_EXPORT_CATALOG) +
  nrow(SUPPLY_CATALOG) * 2 + nrow(CONSUMPTION_CATALOG) * 2 +
  nrow(INVEST_1112_CATALOG) * 2 + nrow(INVEST_1314_CATALOG) * 2
message(sprintf("\n✓ Done — %d/%d NESDC GDP series updated", ok, n_total))
