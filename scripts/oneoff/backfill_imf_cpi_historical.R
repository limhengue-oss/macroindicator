# ══════════════════════════════════════════════════════════════════
#  backfill_imf_cpi_historical.R
#  One-time historical backfill สำหรับ GlobalCPI (IMF_{ISO3}_CPI_{code})
#  — push ข้อมูลย้อนหลังที่ผ่านการ splice/clean มาแล้วจากโปรเจกต์
#  GlobalCPIDBV2 (ดู GlobalCPIDBV2/IMF_analysis/process.md) เข้า Firestore
#  ครั้งเดียว แล้วให้ fetch_imf_cpi.R (push แบบ is_incremental=TRUE) รับช่วง
#  อัพเดทข้อมูลใหม่ไปข้างหน้าต่อเอง
#
#  รันจาก LOCAL เท่านั้น — ไม่มี GitHub Actions workflow คู่กัน เพราะ
#    1) ไฟล์ต้นทาง workfile/cpi_db_final.csv (~78MB) ไม่ได้ commit เข้า
#       repo (ใหญ่เกินไป และใช้ครั้งเดียวจบ)
#    2) เป็น one-time operation จริงๆ ไม่ใช่ scheduled job
#
#  ข้อมูลในไฟล์ (validate ไว้แล้วก่อนเขียนสคริปต์นี้ — ดู session ที่คุยกัน):
#    - 595,248 แถว, ครอบคลุม 192 ประเทศ (191 แมตช์ ISO3 ได้ ยกเว้น
#      "Euro Area (EA)" ซึ่งเป็น aggregate ไม่มี ISO3 — ข้ามไป)
#    - เลือก CPI vs HICP ต่อประเทศไว้แล้วในไฟล์ (ตรวจแล้วว่าไม่มีประเทศไหน
#      มีทั้งสอง index type ปนกัน) และตรงกับ data/imf_index_type.csv ที่
#      fetch_imf_cpi.R ใช้ 100% (0 mismatch) — เลยต่อกับข้อมูลที่
#      fetch_imf_cpi.R จะ fetch ต่อไปข้างหน้าได้โดยไม่มี level jump ที่รอยต่อ
#    - period เป็นวันที่ 1 ของเดือนเสมอ, ไม่มี duplicate key
#    - index_source: native / spliced_from_srp / NA (NA = ไม่มีข้อมูลจริงๆ
#      ทั้งสองแหล่ง ต้อง skip ไม่ใช่ push เป็นค่าว่าง)
#    - COICOP_1999 เป็น label ทางการของ COICOP (ไม่ตรงตัวกับที่
#      fetch_imf_cpi.R ใช้ เช่น "Communication" vs "Information and
#      communication") — map เป็นโค้ด 00-12 ผ่าน CATEGORY_CODE_MAP ด้านล่าง
#
#  Push แบบ is_incremental=FALSE (เขียนทับทั้งก้อน) เพราะเป็นข้อมูล
#  ประวัติศาสตร์ฉบับสมบูรณ์ที่สุดที่มี ไม่ต้อง merge กับอะไร — รันครั้งเดียว
#  แล้วปล่อยให้ fetch_imf_cpi.R (is_incremental=TRUE) merge ข้อมูลใหม่ทับ
#  ต่อจากนี้ไป
#
#  Environment variables:
#    GCP_SA_KEY — service account JSON (ทั้งก้อน เป็น string) — ไม่ใส่ก็รันได้
#                 แต่จะเป็น DRY RUN (ดึงข้อมูลมาพิมพ์ดูเฉย ๆ ไม่ push Firestore)
#
#  รัน (จาก repo root): Rscript scripts/oneoff/backfill_imf_cpi_historical.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(readr)
  library(jsonlite)
  library(httr2)
  library(jose)
  library(xml2)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
IMF_API_BASE <- "https://api.imf.org/external/sdmx/2.1"
CSV_PATH <- "workfile/cpi_db_final.csv"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN  <- sa_json == ""
if (DRY_RUN) message("── GCP_SA_KEY not set — running in DRY RUN mode (no Firestore push)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

source("R/firestore.R")

if (!file.exists(CSV_PATH)) {
  stop(sprintf("ไม่พบ %s — สคริปต์นี้ตั้งใจรันจาก local เท่านั้น (ไฟล์ไม่ได้ commit เข้า repo)", CSV_PATH))
}

# ══════════════════════════════════════════════════════════════════
#  ชื่อประเทศ (IMF formal name) -> ISO3, ผ่าน CL_COUNTRY codelist เดียวกับ
#  ที่ใช้สร้าง data/imf_index_type.csv
# ══════════════════════════════════════════════════════════════════
message("── Fetching IMF CL_COUNTRY codelist...")
resp <- request(paste0(IMF_API_BASE, "/codelist/IMF/CL_COUNTRY/1.6.0")) |>
  req_headers(`User-Agent` = "Mozilla/5.0", Accept = "application/xml") |>
  req_timeout(45) |> req_perform()
doc <- xml2::read_xml(resp_body_string(resp))
codes <- xml2::xml_find_all(doc, "//*[local-name()='Code']")
ids <- xml2::xml_attr(codes, "id")
names_en <- vapply(codes, function(c) {
  n <- xml2::xml_find_first(c, ".//*[local-name()='Name' and @xml:lang='en']")
  if (is.na(n)) NA_character_ else xml2::xml_text(n)
}, character(1))
keep <- !is.na(names_en) & nchar(ids) == 3 & grepl("^[A-Z]{3}$", ids)
codelist <- tibble(iso3 = ids[keep], raw_name = names_en[keep])
message(sprintf("  %d country codes loaded", nrow(codelist)))

# ══════════════════════════════════════════════════════════════════
#  COICOP_1999 label (ทางการ, ตามที่ cpi_db_final.csv ใช้) -> โค้ด 2 หลัก
#  เดียวกับที่ fetch_imf_cpi.R ใช้ (ชื่อ label ต่างกันแต่หมายถึง division
#  เดียวกัน — validate แล้วว่าตรงกับ COICOP 1999 มาตรฐาน 12 division)
# ══════════════════════════════════════════════════════════════════
CATEGORY_CODE_MAP <- c(
  "All Items" = "00",
  "Food and non-alcoholic beverages" = "01",
  "Alcoholic beverages, tobacco and narcotics" = "02",
  "Clothing and footwear" = "03",
  "Housing, water, electricity, gas and other fuels" = "04",
  "Furnishings, household equipment and routine household maintenance" = "05",
  "Health" = "06",
  "Transport" = "07",
  "Communication" = "08",
  "Recreation and culture" = "09",
  "Education" = "10",
  "Restaurants and hotels" = "11",
  "Miscellaneous goods and services" = "12"
)
CATEGORY_NAMES <- c(
  "00" = "All items (headline)",
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

# ══════════════════════════════════════════════════════════════════
#  โหลด + เตรียมข้อมูล
# ══════════════════════════════════════════════════════════════════
message(sprintf("── Reading %s...", CSV_PATH))
raw <- read_csv(CSV_PATH, show_col_types = FALSE)
message(sprintf("  %d rows loaded", nrow(raw)))

prepared <- raw |>
  left_join(codelist, by = c("COUNTRY" = "raw_name")) |>
  mutate(category_code = unname(CATEGORY_CODE_MAP[COICOP_1999])) |>
  filter(!is.na(iso3), !is.na(category_code), !is.na(index_val)) |>
  transmute(iso3, category_code, date = as.character(as.Date(period)), value = index_val)

message(sprintf("  %d rows usable after mapping (dropped %d: unmatched country/category or NA value)",
                 nrow(prepared), nrow(raw) - nrow(prepared)))

series_keys <- prepared |> distinct(iso3, category_code) |> arrange(iso3, category_code)
message(sprintf("── Pushing %d series%s...", nrow(series_keys), if (DRY_RUN) " (dry run)" else ""))

token <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  message("  ✓ token acquired")
}

ok_count <- 0
for (i in seq_len(nrow(series_keys))) {
  cty  <- series_keys$iso3[i]
  code <- series_keys$category_code[i]
  rows <- prepared |> filter(iso3 == cty, category_code == code) |> arrange(date)
  if (nrow(rows) == 0) next

  cat_name <- unname(CATEGORY_NAMES[code])
  doc_id   <- sprintf("IMF_%s_CPI_%s", cty, code)
  name     <- sprintf("IMF CPI Index — %s: %s", cty, cat_name)
  meta <- list(
    fullName = name, currency = "",
    unit = "Index (base year varies by country, per IMF)",
    freq = "Monthly",
    source = "IMF STA CPI 5.0.0, spliced native IX + SRP_IX (historical backfill via GlobalCPIDBV2)"
  )

  df <- rows |> distinct(date, .keep_all = TRUE) |> transmute(date = date, value = value)

  if (DRY_RUN) {
    message(sprintf("  [%d/%d] %s: %d points, %s -> %s", i, nrow(series_keys), doc_id,
                     nrow(df), head(df$date, 1), tail(df$date, 1)))
    ok_count <- ok_count + 1
  } else {
    if (push_series(token, doc_id, name, df, is_incremental = FALSE, meta = meta, quiet = TRUE)) {
      ok_count <- ok_count + 1
    } else {
      message(sprintf("  ✗ %s failed", doc_id))
    }
    if (i %% 100 == 0) message(sprintf("  ... %d/%d pushed", i, nrow(series_keys)))
  }
}

message(sprintf("\n✓ Done — %d/%d IMF CPI historical series backfilled", ok_count, nrow(series_keys)))
