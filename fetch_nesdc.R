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
#  (preliminary) ต้องตัดออกก่อนอ่านตัวเลข — headline GDP column ของแต่ละตาราง:
#    Table 1   คอลัมน์ 14 (N)  = "Gross domestic product (13)"          — Demand, Nominal (level เท่านั้น NESDC ไม่มี %YoY ให้)
#    Table 2   คอลัมน์ 17 (Q)  = "Gross domestic product (CVM) (15)"    — Demand, Real (level)
#    Table 2.1 คอลัมน์ 14 (N)  = "Gross domestic product (CVM) (12)"    — Demand, Real (%YoY)
#    Table 3   คอลัมน์ 26 (Z)  = "Gross Domestic Product (25)"          — Supply, Nominal (level เท่านั้น)
#    Table 4   คอลัมน์ 29 (AC) = "Gross Domestic Product (CVM) (28)"    — Supply, Real (level)
#    Table 4.1 คอลัมน์ 26 (Z)  = "Gross Domestic Product (CVM) (25)"    — Supply, Real (%YoY)
#  (ตัวเลข Nominal และ Real %YoY ของ Demand vs Supply ตรงกันเป๊ะเสมอ เพราะเป็น
#  GDP รวมตัวเดียวกัน แค่มองจากคนละมุม — ใช้ cross-check ความถูกต้องได้)
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
# ปัจจุบันชี้ไปรอบ Q1/2569 (แถลง 18 พ.ค. 2569)
RELEASE_PAGE_URL <- "https://www.nesdc.go.th/en/?p=110061&ddl=110050"

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
# tibble(date, value) — value_col นับแบบ 1-indexed ตาม read_excel
parse_qgdp_table <- function(path, sheet, value_col) {
  raw <- read_excel(path, sheet = sheet, col_names = FALSE, skip = 5)
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
GDP_CATALOG <- tribble(
  ~doc_id,             ~sheet,      ~value_col, ~fullName,                                                          ~unit,
  "NESDC_GDP_NOMINAL",     "Table 1",   14, "Gross Domestic Product — Demand side, Current Prices (Quarterly)",     "Millions of Baht",
  "NESDC_GDP_CVM",         "Table 2",   17, "Gross Domestic Product — Demand side, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_GDP_YOY",         "Table 2.1", 14, "Gross Domestic Product — Demand side, Chain Volume Measures (%YoY, Quarterly)", "Percent",
  "NESDC_GDP_PROD_NOMINAL","Table 3",   26, "Gross Domestic Product — Supply/Production side, Current Prices (Quarterly)", "Millions of Baht",
  "NESDC_GDP_PROD_CVM",    "Table 4",   29, "Gross Domestic Product — Supply/Production side, Chain Volume Measures (Quarterly)", "Millions of Baht (2002 base)",
  "NESDC_GDP_PROD_YOY",    "Table 4.1", 26, "Gross Domestic Product — Supply/Production side, Chain Volume Measures (%YoY, Quarterly)", "Percent"
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

message(sprintf("\n✓ Done — %d/%d NESDC GDP series updated", ok, nrow(GDP_CATALOG)))
