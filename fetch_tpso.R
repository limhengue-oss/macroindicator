# ══════════════════════════════════════════════════════════════════
#  fetch_tpso.R
#  ดึงดัชนีราคาผู้บริโภคทั่วไป (CPIG) และดัชนีราคาผู้ผลิต (PPI) ระดับ
#  ประเทศ จากสำนักงานนโยบายและยุทธศาสตร์การค้า (TPSO) กระทรวงพาณิชย์
#  (index-api.tpso.go.th) → push ขึ้น Firestore
#
#  ขอบเขต: เอาเฉพาะ "หมวดใหญ่" (level 1) เท่านั้น ไม่ลงรายละเอียด
#  รายสินค้าย่อย — CPIG type=TG (ทั่วประเทศ) มี 10 หมวด, PPI type=CPA
#  (ทั่วประเทศ) มี 4 หมวด รวม 14 series
#  หมายเหตุ: สำรวจ endpoint อื่นของ TPSO ไว้ก่อนแล้ว (CPIL/CPIU/CPIP/
#  CMI/K/CSI/IMI-EXI/RFTI/CCI) แต่พบว่าละเอียดเกินไปสำหรับ dashboard นี้
#  (รายจังหวัด/รายสินค้าย่อยเป็นพันรายการ) จึงตัดออก เหลือแค่ CPIG/PPI
#  ระดับประเทศ หมวดใหญ่ตามที่ต้องการ
#
#  Environment variables ที่ต้องตั้ง:
#    GCP_SA_KEY   — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_tpso.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(jsonlite)
  library(httr2)
  library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
BASE_URL   <- "https://index-api.tpso.go.th/OpenApi"

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (R/firestore.R — ใช้ร่วมกับ fetch_*.R
#  อื่นๆ ทั้งหมด, ดู R/firestore.R สำหรับรายละเอียด)
# ══════════════════════════════════════════════════════════════════
source("R/firestore.R")

# ══════════════════════════════════════════════════════════════════
#  PART 2 — TPSO client
# ══════════════════════════════════════════════════════════════════

get_masterdata <- function(index_name) {
  resp <- request(sprintf("%s/%s/Month/MasterData", BASE_URL, index_name)) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))
  fromJSON(resp_body_string(resp), simplifyVector = FALSE)
}

# ดึงข้อมูลรายเดือนของ 1 ปี สำหรับ type หนึ่ง (คืนทุกหมวดในตัวเอง)
fetch_month_data <- function(index_name, type_code, year_base, year) {
  tryCatch({
    body <- list(type = type_code, commodities = list(), yearBase = year_base, year = year)
    resp <- request(sprintf("%s/%s/Month", BASE_URL, index_name)) |>
      req_headers(`Content-Type` = "application/json") |>
      req_body_json(body, auto_unbox = TRUE) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))
    parsed <- fromJSON(resp_body_string(resp), simplifyVector = TRUE, flatten = TRUE)
    if (!is.data.frame(parsed) || nrow(parsed) == 0) return(tibble())
    as_tibble(parsed)
  }, error = function(e) {
    warning(sprintf("  Month SKIP %s/type=%s/year=%s: %s", index_name, type_code, year, e$message))
    tibble()
  })
}

# ดึงข้อมูลทุกปีที่มีของ type หนึ่ง แล้วกรองเหลือแต่หมวดใหญ่ (level 1)
fetch_full_history_level1 <- function(index_name, type_code) {
  md <- get_masterdata(index_name)
  periods <- if (!is.null(md$dataAvailablePeriods)) {
    md$dataAvailablePeriods
  } else {
    Find(\(el) identical(el$type, type_code), md)$dataAvailablePeriods
  }
  # ใช้ period ที่ endYear ล่าสุด (yearBase ปัจจุบัน)
  ends <- map_int(periods, \(p) as.integer(p$endYear))
  p <- periods[[which.max(ends)]]
  year_base  <- as.integer(p$yearBase)
  start_year <- as.integer(p$startYear)
  end_year   <- as.integer(p$endYear)

  message(sprintf("  [%s/%s] yearBase=%d ช่วง %d-%d", index_name, type_code, year_base, start_year, end_year))

  all_years <- map_dfr(start_year:end_year, \(y) {
    Sys.sleep(0.15)  # กัน rate limit
    fetch_month_data(index_name, type_code, year_base, y)
  })

  if (nrow(all_years) == 0) return(tibble())
  all_years |> filter(level == 1)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Catalog: CPIG (TG) + PPI (CPA) หมวดใหญ่ระดับประเทศ
# ══════════════════════════════════════════════════════════════════
CATALOG <- tribble(
  ~label,   ~index_name, ~type_code,
  "CPIG",   "Cpig",      "TG",
  "PPI",    "Ppi",       "CPA"
)

# ══════════════════════════════════════════════════════════════════
#  PART 4 — Main
# ══════════════════════════════════════════════════════════════════
message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

ok_count <- 0
total_count <- 0

for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i, ]
  message(sprintf("── [%d/%d] %s (%s/%s)...", i, nrow(CATALOG), row$label, row$index_name, row$type_code))

  raw <- fetch_full_history_level1(row$index_name, row$type_code)
  if (nrow(raw) == 0) {
    message(sprintf("  ⊘ %s: ไม่มีข้อมูล", row$label))
    next
  }

  categories <- raw |> distinct(commodityCode, commodityNameTH)

  for (j in seq_len(nrow(categories))) {
    ccode <- categories$commodityCode[j]
    cname <- categories$commodityNameTH[j]
    total_count <- total_count + 1

    df <- raw |>
      filter(commodityCode == ccode) |>
      transmute(
        date  = as.Date(sprintf("%d-%02d-01", year - 543L, month)),
        value = as.numeric(index)
      ) |>
      filter(!is.na(date), is.finite(value)) |>
      distinct(date, .keep_all = TRUE) |>
      arrange(date)

    if (nrow(df) == 0) next

    doc_id <- sprintf("TPSO_%s_%s", row$label, ccode)
    meta <- list(
      fullName = sprintf("%s — %s (ทั่วประเทศ)", row$label, cname),
      currency = "",
      unit     = "Index",
      freq     = "Monthly",
      source   = sprintf("TPSO (%s/%s/%s)", row$index_name, row$type_code, ccode)
    )
    name <- sprintf("TPSO %s %s", row$label, cname)

    if (push_series(token, doc_id, name, df, meta = meta)) ok_count <- ok_count + 1
  }
}

message(sprintf("\n✓ Done — %d/%d TPSO series updated", ok_count, total_count))
