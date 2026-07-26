# ══════════════════════════════════════════════════════════════════
#  fetch_bis.R
#  ดึงข้อมูลเศรษฐกิจมหภาคไทยจาก Bank for International Settlements (BIS)
#  SDMX REST API (stats.bis.org) → push ขึ้น Firestore
#  ครอบคลุม: Central Bank Policy Rate, Credit-to-GDP Gap,
#            Credit to Private/Household/Corporate sector (%GDP),
#            Residential Property Price Index (Real/Nominal)
#  หมายเหตุ: BIS ไม่มี Commercial Property Price สำหรับไทย (WS_CPP
#  ครอบคลุมแค่ ~20 ประเทศ ไม่มี TH) จึงไม่ได้ใส่ในชุดนี้
#
#  Environment variables ที่ต้องตั้ง:
#    GCP_SA_KEY   — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_bis.R
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
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (เหมือน fetch_bot.R)
# ══════════════════════════════════════════════════════════════════

get_access_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss = sa$client_email, scope = "https://www.googleapis.com/auth/datastore",
    aud = "https://oauth2.googleapis.com/token", iat = now, exp = now + 3600
  )
  jwt <- jwt_encode_sig(claim, key = gsub("\\\\n", "\n", sa$private_key))
  resp <- request("https://oauth2.googleapis.com/token") |>
    req_body_form(grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion = jwt) |>
    req_perform()
  resp_body_json(resp)$access_token
}

push_series <- function(token, doc_id, name, df, meta = NULL) {
  new_points <- pmap(df, function(date, value) {
    list(mapValue = list(fields = list(
      d = list(stringValue = as.character(date)),
      v = list(doubleValue = value)
    )))
  })

  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )

  fields <- list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = new_points))
  )

  if (!is.null(meta)) {
    fields$meta <- list(mapValue = list(fields = list(
      fullName = list(stringValue = meta$fullName %||% ""),
      currency = list(stringValue = meta$currency %||% ""),
      unit     = list(stringValue = meta$unit     %||% ""),
      freq     = list(stringValue = meta$freq     %||% ""),
      source   = list(stringValue = meta$source   %||% "")
    )))
  }

  body <- list(fields = fields)
  mask_fields <- c("name", "updated", "data")
  if (!is.null(meta)) mask_fields <- c(mask_fields, "meta")

  resp <- request(url) |>
    req_url_query(`updateMask.fieldPaths` = mask_fields, .multi = "explode") |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()

  status <- resp_status(resp)
  if (status >= 300) {
    warning(sprintf("  ✗ %s: HTTP %d — %s", doc_id, status, substr(resp_body_string(resp), 1, 200)))
    return(FALSE)
  }
  message(sprintf("  ✓ %s (%d points)", doc_id, nrow(df)))
  TRUE
}

# ══════════════════════════════════════════════════════════════════
#  PART 2 — BIS SDMX REST client
#  endpoint: https://stats.bis.org/api/v1/data/{flow}/{key}/all?format=csv
#  key เป็น dot-separated ตามลำดับ dimension ของแต่ละ dataflow (ดูใน
#  CATALOG ด้านล่าง — เช็ค dimension order ผ่าน /datastructure/ ก่อนแล้ว)
# ══════════════════════════════════════════════════════════════════

# TIME_PERIOD ของ BIS: Daily = "YYYY-MM-DD", Quarterly = "YYYY-Qn"
parse_bis_period <- function(period, freq) {
  if (freq == "D") return(as.Date(period))
  if (freq == "Q") {
    year <- as.integer(str_sub(period, 1, 4))
    q    <- as.integer(str_sub(period, -1))
    month <- (q - 1) * 3 + 1
    return(as.Date(sprintf("%d-%02d-01", year, month)))
  }
  NA
}

fetch_bis_flow <- function(flow, key, freq, from = "1990-01-01") {
  tryCatch({
    resp <- request(sprintf("https://stats.bis.org/api/v1/data/%s/%s/all", flow, key)) |>
      req_url_query(startPeriod = from, format = "csv") |>
      req_headers(`User-Agent` = "Mozilla/5.0", Accept = "text/csv") |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()

    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))

    body <- resp_body_string(resp)
    if (str_starts(str_trim(body), "<")) {
      # BIS คืน XML <message:Error> เมื่อไม่มีข้อมูล ไม่ใช่ CSV
      return(tibble(date = as.Date(character()), value = numeric()))
    }

    raw <- read.csv(text = body, stringsAsFactors = FALSE)
    if (!all(c("TIME_PERIOD", "OBS_VALUE") %in% names(raw))) {
      return(tibble(date = as.Date(character()), value = numeric()))
    }

    tibble(
      date  = map_vec(raw$TIME_PERIOD, \(p) parse_bis_period(p, freq), .ptype = as.Date(character())),
      value = as.numeric(raw$OBS_VALUE)
    ) |>
      filter(!is.na(date), is.finite(value)) |>
      distinct(date, .keep_all = TRUE) |>
      arrange(date)
  }, error = function(e) {
    warning(sprintf("  bis SKIP %s/%s: %s", flow, key, e$message))
    tibble(date = as.Date(character()), value = numeric())
  })
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Catalog
#  9 ประเทศหลัก × 7 series/ประเทศ — ยืนยันความครอบคลุมข้อมูลแล้วทุกคู่
#  (ยกเว้น commercial property price ที่ BIS ไม่มีข้อมูลของหลายประเทศ
#  ในกลุ่มนี้ เลยไม่ได้ใส่)
# ══════════════════════════════════════════════════════════════════
COUNTRIES <- tribble(
  ~cty, ~country_name,
  "TH", "Thailand",
  "US", "United States",
  "XM", "Eurozone",
  "GB", "United Kingdom",
  "JP", "Japan",
  "KR", "South Korea",
  "IN", "India",
  "ID", "Indonesia",
  "CN", "China"
)

SERIES_TEMPLATES <- tribble(
  ~suffix,              ~flow,            ~key_tpl,               ~freq, ~name_tpl,                                            ~unit,
  "CBPOL",              "WS_CBPOL",       "D.%s",                 "D",   "Central Bank Policy Rate — %s",                     "Percent",
  "CREDIT_GAP",         "WS_CREDIT_GAP",  "Q.%s.P.A.C",           "Q",   "Credit-to-GDP Gap (Private Non-Financial Sector) — %s", "Percentage points",
  "CREDIT_PRIVATE_GDP", "WS_TC",          "Q.%s.P.A.M.770.A",     "Q",   "Credit to Private Non-Financial Sector (%% of GDP) — %s", "Percent of GDP",
  "CREDIT_HH_GDP",      "WS_TC",          "Q.%s.H.A.M.770.A",     "Q",   "Credit to Households (%% of GDP) — %s",             "Percent of GDP",
  "CREDIT_CORP_GDP",    "WS_TC",          "Q.%s.N.A.M.770.A",     "Q",   "Credit to Non-Financial Corporations (%% of GDP) — %s", "Percent of GDP",
  "RPP_REAL",           "WS_SPP",         "Q.%s.R.628",           "Q",   "Residential Property Price Index (Real) — %s",      "Index",
  "RPP_NOMINAL",        "WS_SPP",         "Q.%s.N.628",           "Q",   "Residential Property Price Index (Nominal) — %s",   "Index"
)

CATALOG <- COUNTRIES |>
  cross_join(SERIES_TEMPLATES) |>
  mutate(
    doc_id   = sprintf("BIS_%s_%s", cty, suffix),
    key      = sprintf(key_tpl, cty),
    fullName = sprintf(name_tpl, country_name)
  ) |>
  select(doc_id, flow, key, freq, fullName, unit)

# ══════════════════════════════════════════════════════════════════
#  PART 4 — Main
# ══════════════════════════════════════════════════════════════════
message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Fetching + pushing ", nrow(CATALOG), " BIS series...")

ok_count <- 0
for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i, ]
  message(sprintf("  [%d/%d] %s (%s/%s)...", i, nrow(CATALOG), row$doc_id, row$flow, row$key))

  df <- fetch_bis_flow(row$flow, row$key, row$freq)
  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no data", row$doc_id))
    next
  }

  meta <- list(
    fullName = row$fullName,
    currency = "",
    unit     = row$unit,
    freq     = if (row$freq == "D") "Daily" else "Quarterly",
    source   = sprintf("BIS (%s/%s)", row$flow, row$key)
  )
  name <- sprintf("BIS %s", row$fullName)

  if (push_series(token, row$doc_id, name, df, meta = meta)) ok_count <- ok_count + 1
}

message(sprintf("\n✓ Done — %d/%d BIS series updated", ok_count, nrow(CATALOG)))
