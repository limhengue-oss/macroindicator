# ══════════════════════════════════════════════════════════════════
#  fetch_imf.R
#  ดึง Quarterly GDP จาก IMF SDMX 3.0 API (api.imf.org, dataflow QNEA)
#  → push ขึ้น Firestore
#
#  9 ประเทศหลัก (ตรงกับกลุ่มที่ใช้ใน fetch_bis.R) — ยืนยัน coverage แล้ว
#  ทุกประเทศผ่าน dry run จริง ยกเว้นจีนที่ไม่มี seasonally-adjusted quarterly
#  GDP รายงานให้ IMF เลยใช้ NSA (not seasonally adjusted) แทนเฉพาะจีน
#
#  Environment variables:
#    GCP_SA_KEY   — service account JSON (ทั้งก้อน เป็น string) — ไม่ใส่ก็รันได้
#                   แต่จะเป็น DRY RUN (ดึงข้อมูลมาพิมพ์ดูเฉย ๆ ไม่ push Firestore)
#    IMF_API_KEY  — IMF API subscription key (ไม่บังคับ — จากการทดสอบ
#                   endpoint นี้ตอบข้อมูลจริงได้แม้ไม่ใส่ key ก็ตาม แต่ใส่
#                   ไว้เพื่อกัน rate limit ที่ต่ำกว่าถ้าไม่มี key)
#
#  รัน local:  Rscript fetch_imf.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(stringr)
  library(jsonlite)
  library(httr2)
  library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN  <- sa_json == ""
if (DRY_RUN) message("── GCP_SA_KEY not set — running in DRY RUN mode (no Firestore push)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

imf_api_key <- Sys.getenv("IMF_API_KEY")  # อาจว่างได้ (ทดสอบแล้วไม่ใส่ก็ดึงได้)

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (R/firestore.R — ใช้ร่วมกับ fetch_*.R
#  อื่นๆ ทั้งหมด, ดู R/firestore.R สำหรับรายละเอียด)
# ══════════════════════════════════════════════════════════════════
source("R/firestore.R")

# ══════════════════════════════════════════════════════════════════
#  PART 2 — IMF SDMX 3.0 client
#  endpoint: https://api.imf.org/external/sdmx/3.0/data/dataflow/IMF.STA/{flow}/~/{key}
#  รองรับ TIME_PERIOD 2 รูปแบบ: "YYYY-Qn" (quarterly) และ "YYYY-Mnn" (monthly)
# ══════════════════════════════════════════════════════════════════

parse_imf_period <- function(period) {
  year <- as.integer(str_sub(period, 1, 4))
  tag  <- str_sub(period, 6, 6)
  num  <- as.integer(str_sub(period, 7))
  month <- if (tag == "Q") (num - 1) * 3 + 1 else num
  as.Date(sprintf("%d-%02d-01", year, month))
}

# fetch generic — key เป็น dot-separated ตาม dimension order ของแต่ละ dataflow
fetch_imf_flow <- function(flow, key) {
  tryCatch({
    req <- request(sprintf("https://api.imf.org/external/sdmx/3.0/data/dataflow/IMF.STA/%s/~/%s", flow, key)) |>
      req_headers(`User-Agent` = "Mozilla/5.0", Accept = "application/json")
    if (imf_api_key != "") req <- req |> req_headers(`Ocp-Apim-Subscription-Key` = imf_api_key)

    resp <- req |> req_error(is_error = \(r) FALSE) |> req_perform()
    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))

    j <- resp_body_json(resp)
    series_list <- j$data$dataSets[[1]]$series
    if (is.null(series_list) || length(series_list) == 0) {
      return(tibble(date = as.Date(character()), value = numeric()))
    }

    obs_list  <- series_list[[1]]$observations
    times     <- j$data$structures[[1]]$dimensions$observation[[1]]$values
    time_vals <- map_chr(times, \(t) t$value)

    tibble(
      idx   = as.integer(names(obs_list)),
      value = map_dbl(obs_list, \(o) as.numeric(o[[1]]))
    ) |>
      mutate(date = map_vec(time_vals[idx + 1], parse_imf_period, .ptype = as.Date(character()))) |>
      filter(!is.na(date), is.finite(value)) |>
      distinct(date, .keep_all = TRUE) |>
      arrange(date) |>
      select(date, value)
  }, error = function(e) {
    warning(sprintf("  imf SKIP %s/%s: %s", flow, key, e$message))
    tibble(date = as.Date(character()), value = numeric())
  })
}

# QNEA key = COUNTRY.INDICATOR.PRICE_TYPE.S_ADJUSTMENT.TYPE_OF_TRANSFORMATION.FREQUENCY
fetch_imf_qnea <- function(country, indicator = "B1GQ", price_type = "Q",
                            s_adj = "SA", transformation = "XDC", freq = "Q") {
  key <- paste(country, indicator, price_type, s_adj, transformation, freq, sep = ".")
  fetch_imf_flow("QNEA", key)
}

# FSIC key = COUNTRY.SECTOR.INDICATOR.FREQUENCY (SECTOR = S12CFSI, Deposit Takers)
fetch_imf_fsic <- function(country, indicator, sector = "S12CFSI", freq = "Q") {
  key <- paste(country, sector, indicator, freq, sep = ".")
  fetch_imf_flow("FSIC", key)
}

# CPI_WCA key = COUNTRY.INDEX_TYPE.COICOP_1999.TYPE_OF_TRANSFORMATION.FREQUENCY
fetch_imf_cpi_wca <- function(area, index_type = "CPI", coicop = "_T",
                               transformation = "YOY_PCH_PA_PT", freq = "M") {
  key <- paste(area, index_type, coicop, transformation, freq, sep = ".")
  fetch_imf_flow("CPI_WCA", key)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Catalog
# ══════════════════════════════════════════════════════════════════

# 3a. GDP รายไตรมาส (QNEA) — 9 ประเทศหลัก, s_adj ตาม coverage จริงที่เช็คแล้ว
GDP_COUNTRIES <- tribble(
  ~cty,   ~country_name,    ~s_adj,
  "THA",  "Thailand",       "SA",
  "USA",  "United States",  "SA",
  "G163", "Eurozone",       "SA",
  "GBR",  "United Kingdom", "SA",
  "JPN",  "Japan",          "SA",
  "KOR",  "South Korea",    "SA",
  "IND",  "India",          "SA",
  "IDN",  "Indonesia",      "SA",
  "CHN",  "China",          "NSA"
)

# 3b. Financial Soundness Indicators (FSIC) — 8 ประเทศ (ไม่มี Eurozone
# aggregate ให้ใน FSIC — เป็นข้อมูลระดับธนาคารรายประเทศเท่านั้น)
FSIC_COUNTRIES <- tribble(
  ~cty,  ~country_name,
  "THA", "Thailand",
  "USA", "United States",
  "GBR", "United Kingdom",
  "JPN", "Japan",
  "KOR", "South Korea",
  "IND", "India",
  "IDN", "Indonesia",
  "CHN", "China"
)
FSIC_INDICATORS <- tribble(
  ~suffix, ~indicator,        ~label,
  "CAR",   "FSI688_CFSI_PT",  "Capital Adequacy Ratio (Regulatory Capital to Risk-Weighted Assets)",
  "NPL",   "AQ12_CFSI_PT",    "Nonperforming Loans to Total Gross Loans",
  "ROE",   "ROE_CFSI_PT",     "Return on Equity"
)

# 3c. CPI World & Regional Aggregates (CPI_WCA) — เน้น regional/world ตามที่ขอ
CPI_WCA_AREAS <- tribble(
  ~code,  ~area_name,
  "G001", "World",
  "G110", "Advanced Economies",
  "G119", "G7",
  "G120", "G20",
  "G200", "Emerging Market and Developing Economies",
  "U002", "Africa",
  "U009", "Oceania",
  "U019", "Americas",
  "U142", "Asia",
  "U150", "Europe"
)

# ══════════════════════════════════════════════════════════════════
#  PART 4 — Main
# ══════════════════════════════════════════════════════════════════
token <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  message("  ✓ token acquired")
}

push_or_report <- function(doc_id, name, df, meta) {
  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no data", doc_id))
    return(FALSE)
  }
  if (DRY_RUN) {
    message(sprintf("  ✓ %s: %d points fetched — latest %s = %s",
                     doc_id, nrow(df), tail(df$date, 1), tail(df$value, 1)))
    return(TRUE)
  }
  push_series(token, doc_id, name, df, meta = meta)
}

ok_count <- 0

# ── GDP ──
message("── [1/3] Fetching ", if (DRY_RUN) "(dry run) " else "", "GDP for ", nrow(GDP_COUNTRIES), " countries...")
for (i in seq_len(nrow(GDP_COUNTRIES))) {
  row <- GDP_COUNTRIES[i, ]
  doc_id <- sprintf("IMF_%s_GDP_QUARTERLY", row$cty)
  message(sprintf("  [%d/%d] %s (%s)...", i, nrow(GDP_COUNTRIES), doc_id, row$cty))

  df <- fetch_imf_qnea(row$cty, s_adj = row$s_adj)
  Sys.sleep(0.6)  # กัน rate limit (IMF: 10 calls/5 วินาที)

  adj_label <- if (row$s_adj == "SA") "Seasonally Adjusted" else "Not Seasonally Adjusted"
  meta <- list(
    fullName = sprintf("GDP, Constant Prices, %s — %s", adj_label, row$country_name),
    currency = "", unit = "Domestic Currency (unscaled)", freq = "Quarterly",
    source = sprintf("IMF QNEA (%s.B1GQ.Q.%s.XDC.Q)", row$cty, row$s_adj)
  )
  if (push_or_report(doc_id, sprintf("IMF %s", meta$fullName), df, meta)) ok_count <- ok_count + 1
}

# ── FSIC ──
n_fsic <- nrow(FSIC_COUNTRIES) * nrow(FSIC_INDICATORS)
message("── [2/3] Fetching ", if (DRY_RUN) "(dry run) " else "", "FSIC for ", nrow(FSIC_COUNTRIES), " countries × ", nrow(FSIC_INDICATORS), " indicators...")
k <- 0
for (i in seq_len(nrow(FSIC_COUNTRIES))) {
  crow <- FSIC_COUNTRIES[i, ]
  for (j in seq_len(nrow(FSIC_INDICATORS))) {
    irow <- FSIC_INDICATORS[j, ]
    k <- k + 1
    doc_id <- sprintf("IMF_%s_FSI_%s", crow$cty, irow$suffix)
    message(sprintf("  [%d/%d] %s (%s)...", k, n_fsic, doc_id, crow$cty))

    df <- fetch_imf_fsic(crow$cty, irow$indicator)
    Sys.sleep(0.6)

    meta <- list(
      fullName = sprintf("%s — %s", irow$label, crow$country_name),
      currency = "", unit = "Percent", freq = "Quarterly",
      source = sprintf("IMF FSIC (%s.S12CFSI.%s.Q)", crow$cty, irow$indicator)
    )
    if (push_or_report(doc_id, sprintf("IMF %s", meta$fullName), df, meta)) ok_count <- ok_count + 1
  }
}

# ── CPI World & Regional Aggregates ──
message("── [3/3] Fetching ", if (DRY_RUN) "(dry run) " else "", "CPI_WCA for ", nrow(CPI_WCA_AREAS), " regions/aggregates...")
for (i in seq_len(nrow(CPI_WCA_AREAS))) {
  row <- CPI_WCA_AREAS[i, ]
  doc_id <- sprintf("IMF_%s_CPI_YOY", row$code)
  message(sprintf("  [%d/%d] %s (%s)...", i, nrow(CPI_WCA_AREAS), doc_id, row$area_name))

  df <- fetch_imf_cpi_wca(row$code)
  Sys.sleep(0.6)

  meta <- list(
    fullName = sprintf("CPI, %%YoY — %s", row$area_name),
    currency = "", unit = "Percent", freq = "Monthly",
    source = sprintf("IMF CPI_WCA (%s.CPI._T.YOY_PCH_PA_PT.M)", row$code)
  )
  if (push_or_report(doc_id, sprintf("IMF %s", meta$fullName), df, meta)) ok_count <- ok_count + 1
}

n_total <- nrow(GDP_COUNTRIES) + n_fsic + nrow(CPI_WCA_AREAS)
message(sprintf("\n✓ Done — %d/%d IMF series updated", ok_count, n_total))
