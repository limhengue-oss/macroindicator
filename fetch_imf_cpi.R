# ══════════════════════════════════════════════════════════════════
#  fetch_imf_cpi.R
#  ดึงดัชนีราคาผู้บริโภค (CPI, index ดิบ) รายเดือน จาก IMF STA CPI(5.0.0)
#  — ทุกประเทศที่ IMF เผยแพร่ (~150+ ประเทศ) x หัวข้อรวม + 12 หมวด COICOP
#  → push ขึ้น Firestore เป็น series แยกทีละประเทศ/หมวด (raw index, ให้
#  dashboard คำนวณ %YoY เองแบบเดียวกับ TPSO_CPIG)
#
#  แหล่งอ้างอิง: พอร์ตวิธี wildcard bulk-fetch (ยิง request เดียวได้ทุก
#  ประเทศ) มาจากโปรเจกต์ GlobalCPIDB (scraper/R/imf_bulk_lib.R) ซึ่ง
#  live-test ไว้แล้วว่าใช้งานได้ — endpoint คือ api.imf.org/external/sdmx/2.1
#  (SDMX 2.1 XML, คนละตัวกับ SDMX 3.0 JSON ที่ fetch_imf.R ใช้สำหรับ
#  GDP/FSI/CPI aggregate) ต้องบังคับ Accept: application/xml เพราะ default
#  content negotiation ของ endpoint นี้จะได้ SDMX-JSON ที่ keyed แบบ
#  positional index แทน ซึ่งพาร์สยากกว่า
#
#  ขอบเขต: ดึงเฉพาะ index (IX), ไม่ดึง weight (WGT_PT) — ไม่ได้ใช้ในหน้านี้
#  Monthly เท่านั้น (ตัด Quarterly fallback ออก per หน้า Inflation by Country
#  ที่ต้องการเทียบ %YoY รายเดือนทุกเส้นบนแกนเวลาเดียวกัน — ประเทศที่ไม่มี
#  รายเดือนจะไม่ถูกดึงเลย แทนที่จะ mix ความถี่กัน)
#
#  CPI vs HICP: IMF มี 2 ประเภท index (INDEX_TYPE dimension) — 32 ประเทศ
#  (ส่วนใหญ่ EU/EFTA) รายงานทั้งคู่ ซึ่งไม่เท่ากันเป๊ะ (correlation สูงแต่
#  ไม่ใช่ตัวเดียวกัน — ห้ามผสม) สคริปต์นี้เลือก CPI หรือ HICP ต่อประเทศตาม
#  data/imf_index_type.csv (ประเทศไหนไม่อยู่ในลิสต์ = fallback "CPI") — ไฟล์
#  นี้มาจากการวิเคราะห์ completeness แบบละเอียด (นับเดือนที่ index ครบ 13
#  หมวด + weight ครบ) ที่ทำแยกไว้ในโปรเจกต์ GlobalCPIDBV2
#  (IMF_analysis/process.md, chosen_index_type.csv) — แปลงชื่อประเทศ (IMF
#  formal name) เป็น ISO3 ด้วย CL_COUNTRY codelist แล้ว commit ไว้ที่นี่
#  ครั้งเดียว ไม่ได้ query ข้าม repo ตอนรันจริง (GitHub Actions เห็นแค่ repo
#  นี้) — 27/191 ประเทศเลือก HICP ที่เหลือ CPI
#
#  ไม่ splice SRP_IX (Standard Reference Period index) เพื่อยืดประวัติย้อน
#  หลังก่อนปี 2014 เหมือนที่ GlobalCPIDBV2 ทำ — งานนั้นเป็น one-time
#  historical backfill ที่ทำแยกจากโปรเจกต์นั้นแล้ว (ดู
#  scripts/oneoff/backfill_imf_cpi_historical.R) สคริปต์นี้สนใจแค่การ
#  อัพเดทข้อมูลไปข้างหน้า (native IX เท่านั้นก็พอ เพราะ IMF รายงาน native IX
#  ต่อเนื่องสำหรับข้อมูลปัจจุบัน/อนาคต ไม่มีช่องว่างต้อง splice)
#
#  push เป็น is_incremental=TRUE (merge กับของเดิม ไม่ทับทั้งก้อน) โดยตั้งใจ
#  — เพราะ START_PERIOD="2000-01" ของสคริปต์นี้สั้นกว่าประวัติที่
#  backfill_imf_cpi_historical.R ใส่ไว้ (ย้อนถึง 1914 บางประเทศ) ถ้า push
#  แบบ full-replace ทุกรอบ cron จะเขียนทับประวัติเก่าที่ backfill ใส่ไว้หาย
#  หมด เหลือแค่ปี 2000 เป็นต้นไป
#  Environment variables:
#    GCP_SA_KEY  — service account JSON (ทั้งก้อน เป็น string) — ไม่ใส่ก็รันได้
#                  แต่จะเป็น DRY RUN (ดึงข้อมูลมาพิมพ์ดูเฉย ๆ ไม่ push Firestore)
#    IMF_API_KEY — IMF API subscription key (ไม่บังคับ — endpoint นี้ตอบ
#                  ข้อมูลจริงได้แม้ไม่ใส่ key แต่ใส่ไว้กัน rate limit ต่ำ)
#
#  รัน local:  Rscript fetch_imf_cpi.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
#
#  หมายเหตุ: series ที่ได้มีจำนวนมาก (ประเทศ x หมวด ~1,700+ series) รันแล้ว
#  ใช้เวลานานกว่า fetch_imf.R ปกติมาก (push ทีละ doc ไป Firestore) แนะนำให้
#  รันแบบ dry_run ก่อนเพื่อดู coverage ก่อน push จริง
#
#  START_PERIOD = 2000-01 (live-test แล้ว: IMF มีข้อมูลย้อนถึงปี 2000 จริง
#  สำหรับส่วนใหญ่ของประเทศที่มีข้อมูล — ~75/~198 ประเทศเริ่มเดือน 2000-01
#  พอดี ที่เหลือส่วนใหญ่เริ่มก่อนปี 2015 — full wildcard call (Monthly, 13
#  หมวด, ทุกประเทศ) ที่ startPeriod นี้ตอบกลับมา ~60MB/355k+ rows วัดจริง
#  แล้วว่า fetch+parse ใช้เวลารวม ~2-3 นาที ไม่ timeout (req_timeout ตั้งไว้
#  180s ต่อ request เผื่อ margin)
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(jsonlite)
  library(httr2)
  library(jose)
  library(xml2)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
IMF_API_BASE <- "https://api.imf.org/external/sdmx/2.1"
IMF_CPI_FLOW <- "IMF.STA,CPI,5.0.0"
START_PERIOD <- "2000-01"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN  <- sa_json == ""
if (DRY_RUN) message("── GCP_SA_KEY not set — running in DRY RUN mode (no Firestore push)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

imf_api_key <- Sys.getenv("IMF_API_KEY")  # อาจว่างได้

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (R/firestore.R — ใช้ร่วมกับ fetch_*.R
#  อื่นๆ ทั้งหมด, ดู R/firestore.R สำหรับรายละเอียด)
# ══════════════════════════════════════════════════════════════════
source("R/firestore.R")

# ══════════════════════════════════════════════════════════════════
#  PART 2 — IMF SDMX 2.1 wildcard client (CPI, all countries)
# ══════════════════════════════════════════════════════════════════

# 12 COICOP 1999 divisions (มาตรฐานเดียวกับที่ GlobalCPIDB/harmonize.R ใช้)
COICOP_NAMES <- c(
  "01" = "Food and non-alcoholic beverages",
  "02" = "Alcoholic beverages, tobacco and narcotics",
  "03" = "Clothing and footwear",
  "04" = "Housing, water, electricity, gas and other fuels",
  "05" = "Furnishings, household equipment and routine household maintenance",
  "06" = "Health",
  "07" = "Transport",
  "08" = "Information and communication",
  "09" = "Recreation, sport and culture",
  "10" = "Education",
  "11" = "Restaurants and accommodation services",
  "12" = "Insurance and financial services / Miscellaneous goods and services"
)
CATEGORY_NAMES <- c("00" = "All items (headline)", COICOP_NAMES)
# names = raw IMF COICOP_1999 code ("_T","CP01",...), values = 2-digit doc code ("00","01",...)
COICOP_CODES <- c("_T" = "00", setNames(names(COICOP_NAMES), paste0("CP", names(COICOP_NAMES))))

# ISO3 -> "CPI"/"HICP" ตามที่วิเคราะห์ไว้ใน GlobalCPIDBV2 (ดู comment header
# ด้านบน) — ประเทศไหนไม่อยู่ในไฟล์ (เช่นประเทศใหม่ที่ IMF เพิ่งเริ่มรายงาน
# หลังวันที่วิเคราะห์) fallback เป็น "CPI" เพราะเป็นแบบที่ประเทศส่วนใหญ่
# รายงาน
INDEX_TYPE_MAP <- local({
  df <- read.csv("data/imf_index_type.csv", stringsAsFactors = FALSE)
  setNames(df$index_type, df$iso3)
})
index_type_for <- function(cty) unname(INDEX_TYPE_MAP[cty]) %||% "CPI"

imf_apply_headers <- function(req) {
  req <- req |> req_headers(`User-Agent` = "Mozilla/5.0", Accept = "application/xml")
  if (nzchar(imf_api_key)) req <- req |> req_headers(`Ocp-Apim-Subscription-Key` = imf_api_key)
  req
}

# ดึงชื่อประเทศแบบเต็มจาก codelist ของ IMF เอง (ไม่ทำตารางแก้ชื่อเองแบบ
# GlobalCPIDB เพราะที่นี่ใช้แค่แสดงผล ไม่ต้อง merge ข้ามแหล่งข้อมูล — ตัด
# จาก comma ตัวแรกก็พอให้อ่านง่ายขึ้นกว่าโค้ด ISO3 ดิบ)
imf_fetch_country_names <- function() {
  resp <- tryCatch(
    request(paste0(IMF_API_BASE, "/codelist/IMF/CL_COUNTRY/1.6.0")) |>
      imf_apply_headers() |>
      req_timeout(45) |>
      req_error(is_error = function(resp) FALSE) |>
      req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp) || resp_status(resp) >= 300) {
    message("imf_cpi: CL_COUNTRY fetch failed, falling back to raw ISO3 codes as names")
    return(character(0))
  }
  doc <- tryCatch(xml2::read_xml(resp_body_string(resp)), error = function(e) NULL)
  if (is.null(doc)) return(character(0))
  codes <- xml2::xml_find_all(doc, "//*[local-name()='Code']")
  ids <- xml2::xml_attr(codes, "id")
  names_en <- vapply(codes, function(c) {
    n <- xml2::xml_find_first(c, ".//*[local-name()='Name' and @xml:lang='en']")
    if (is.na(n)) NA_character_ else xml2::xml_text(n)
  }, character(1))
  keep <- !is.na(names_en) & nchar(ids) == 3 & grepl("^[A-Z]{3}$", ids)
  cleaned <- trimws(sub(",.*$", "", names_en[keep]))
  setNames(cleaned, ids[keep])
}

imf_build_cpi_url <- function(coicop_codes, index_type, freq, start_period) {
  key <- paste("", index_type, paste(coicop_codes, collapse = "+"), "IX", freq, sep = ".")
  paste0(IMF_API_BASE, "/data/", IMF_CPI_FLOW, "/", key, "?startPeriod=", start_period)
}

# แปลง "2020-M06" -> "2020-06-01"; "2020-Q1" -> "2020-01-01" (ต้นไตรมาส)
imf_period_to_date <- function(period_raw, freq_label) {
  out <- rep(NA_character_, length(period_raw))
  is_m <- freq_label == "monthly"
  if (any(is_m)) {
    m <- regmatches(period_raw[is_m], regexec("^(\\d{4})-M(\\d{2})$", period_raw[is_m]))
    out[is_m] <- vapply(m, function(x) if (length(x) == 3) sprintf("%s-%s-01", x[2], x[3]) else NA_character_, character(1))
  }
  is_q <- !is_m
  if (any(is_q)) {
    q <- regmatches(period_raw[is_q], regexec("^(\\d{4})-Q(\\d)$", period_raw[is_q]))
    out[is_q] <- vapply(q, function(x) {
      if (length(x) != 3) return(NA_character_)
      mo <- (as.integer(x[3]) - 1) * 3 + 1
      sprintf("%s-%02d-01", x[2], mo)
    }, character(1))
  }
  out
}

imf_parse_cpi_xml <- function(xml_text, freq_label) {
  doc <- tryCatch(xml2::read_xml(xml_text), error = function(e) NULL)
  if (is.null(doc)) return(tibble())
  xml2::xml_ns_strip(doc)
  series_nodes <- xml2::xml_find_all(doc, ".//Series")
  if (length(series_nodes) == 0) return(tibble())
  rows <- map(series_nodes, function(s) {
    country_code <- xml2::xml_attr(s, "COUNTRY")
    coicop_raw   <- xml2::xml_attr(s, "COICOP_1999")
    obs <- xml2::xml_find_all(s, ".//Obs")
    if (length(obs) == 0) return(NULL)
    period_raw <- xml2::xml_attr(obs, "TIME_PERIOD")
    value <- suppressWarnings(as.numeric(xml2::xml_attr(obs, "OBS_VALUE")))
    keep <- !is.na(value)
    if (!any(keep)) return(NULL)
    tibble(
      country_code = country_code, coicop_raw = coicop_raw,
      period_raw = period_raw[keep], value = value[keep], freq_label = freq_label
    )
  })
  bind_rows(compact(rows))
}

imf_fetch_cpi_wildcard <- function(index_type, freq, freq_label, start_period) {
  url <- imf_build_cpi_url(names(COICOP_CODES), index_type, freq, start_period)
  resp <- tryCatch(
    request(url) |> imf_apply_headers() |> req_timeout(180) |>
      req_error(is_error = function(resp) FALSE) |> req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp) || resp_status(resp) >= 300) {
    warning(sprintf("imf_cpi: request failed for %s/IX/%s", index_type, freq))
    return(tibble())
  }
  imf_parse_cpi_xml(resp_body_string(resp), freq_label) |> mutate(index_type = index_type)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Fetch + push
# ══════════════════════════════════════════════════════════════════

message("── Fetching IMF CPI index, monthly, all countries (CPI)...")
ix_cpi <- imf_fetch_cpi_wildcard("CPI", "M", "monthly", START_PERIOD)
message(sprintf("  CPI -> %d rows, %d countries", nrow(ix_cpi), n_distinct(ix_cpi$country_code)))

message("── Fetching IMF CPI index, monthly, all countries (HICP)...")
ix_hicp <- imf_fetch_cpi_wildcard("HICP", "M", "monthly", START_PERIOD)
message(sprintf("  HICP -> %d rows, %d countries", nrow(ix_hicp), n_distinct(ix_hicp$country_code)))

# World & Regional aggregates (IMF.STA,CPI_WCA,3.0.0 — คนละ dataflow กับ
# CPI ปกติ) — headline (_T) เท่านั้น ไม่มี COICOP breakdown ให้ (เช็คสดแล้ว
# CP01 ของ World ตอบ 0 series) ใช้ area code ตรงๆ เป็น "ISO3" ในโค้ดเดิม
# (บางโค้ดยาว 4 ตัวอักษร เช่น G001, U002 — regex ฝั่ง index.html รองรับแล้ว)
CPI_WCA_FLOW <- "IMF.STA,CPI_WCA,3.0.0"
CPI_WCA_AREAS <- c(
  G001 = "World", G110 = "Advanced Economies", G119 = "G7", G120 = "G20",
  G200 = "Emerging Market and Developing Economies", U002 = "Africa",
  U009 = "Oceania", U019 = "Americas", U142 = "Asia", U150 = "Europe"
)
message("── Fetching IMF CPI World & Regional Aggregates (headline only)...")
wca_url <- paste0(IMF_API_BASE, "/data/", CPI_WCA_FLOW, "/.CPI._T.IX.M?startPeriod=", START_PERIOD)
wca_resp <- tryCatch(
  request(wca_url) |> imf_apply_headers() |> req_timeout(60) |>
    req_error(is_error = function(resp) FALSE) |> req_perform(),
  error = function(e) NULL
)
ix_wca <- if (!is.null(wca_resp) && resp_status(wca_resp) < 300) {
  imf_parse_cpi_xml(resp_body_string(wca_resp), "monthly") |>
    filter(country_code %in% names(CPI_WCA_AREAS)) |> mutate(index_type = "CPI")
} else tibble()
message(sprintf("  WCA -> %d rows, %d areas", nrow(ix_wca), n_distinct(ix_wca$country_code)))

# เลือก CPI หรือ HICP ต่อประเทศตาม INDEX_TYPE_MAP (ดู comment header) —
# ทิ้งอีกฝั่งไปเลย ไม่ผสมสอง index type เป็น series เดียว (WCA area code ไม่
# อยู่ใน INDEX_TYPE_MAP เลย fallback "CPI" ซึ่งตรงกับ tag ที่ตั้งไว้แล้วพอดี)
ix_m <- bind_rows(ix_cpi, ix_hicp, ix_wca) |>
  filter(index_type == vapply(country_code, index_type_for, character(1)))
message(sprintf("  IX/M -> %d rows, %d countries", nrow(ix_m), n_distinct(ix_m$country_code)))

ix_all <- ix_m |>
  mutate(
    category_code = unname(COICOP_CODES[coicop_raw]),
    date = imf_period_to_date(period_raw, freq_label)
  ) |>
  filter(!is.na(category_code), !is.na(date))

message(sprintf("── Combined: %d rows, %d countries, %d country x category series",
                 nrow(ix_all), n_distinct(ix_all$country_code),
                 nrow(distinct(ix_all, country_code, category_code))))

country_names <- imf_fetch_country_names()
country_label <- function(cty) unname(country_names[cty]) %||% unname(CPI_WCA_AREAS[cty]) %||% cty

token <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  message("  ✓ token acquired")
}

series_keys <- ix_all |> distinct(country_code, category_code) |> arrange(country_code, category_code)
message(sprintf("── Pushing %d series%s...", nrow(series_keys), if (DRY_RUN) " (dry run)" else ""))

ok_count <- 0
for (i in seq_len(nrow(series_keys))) {
  cty  <- series_keys$country_code[i]
  code <- series_keys$category_code[i]
  rows <- ix_all |> filter(country_code == cty, category_code == code) |> arrange(date)
  if (nrow(rows) == 0) next

  cat_name  <- unname(CATEGORY_NAMES[code])
  cname     <- country_label(cty)
  idx_type  <- index_type_for(cty)
  doc_id    <- sprintf("IMF_%s_CPI_%s", cty, code)
  name      <- sprintf("IMF CPI Index — %s: %s", cname, cat_name)
  meta <- list(
    fullName = name, currency = "",
    unit = "Index (base year varies by country, per IMF)",
    freq = "Monthly",
    source = sprintf("IMF STA CPI 5.0.0 (%s.%s.%s.IX.M)", cty, idx_type,
                      names(COICOP_CODES)[COICOP_CODES == code][1])
  )

  df <- rows |> distinct(date, .keep_all = TRUE) |> transmute(date = date, value = value)

  if (DRY_RUN) {
    message(sprintf("  [%d/%d] %s: %d points, latest %s = %s", i, nrow(series_keys), doc_id,
                     nrow(df), tail(df$date, 1), tail(df$value, 1)))
    ok_count <- ok_count + 1
  } else {
    if (push_series(token, doc_id, name, df, is_incremental = TRUE, meta = meta, quiet = TRUE)) {
      ok_count <- ok_count + 1
    } else {
      message(sprintf("  ✗ %s failed", doc_id))
    }
    if (i %% 100 == 0) message(sprintf("  ... %d/%d pushed", i, nrow(series_keys)))
  }
}

message(sprintf("\n✓ Done — %d/%d IMF CPI series updated", ok_count, nrow(series_keys)))
