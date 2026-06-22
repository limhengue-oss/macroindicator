# ══════════════════════════════════════════════════════════════════
#  fetch_and_push.R
#  ดึงข้อมูล (tidyquant + fredr) → push ขึ้น Firestore REST API
#
#  Environment variables ที่ต้องตั้ง:
#    FRED_API_KEY              — FRED API key
#    GCP_SA_KEY                — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_and_push.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(tidyquant)
  library(fredr)
  library(dplyr)
  library(tidyr)
  library(purrr)
  library(tibble)
  library(stringr)
  library(lubridate)
  library(jsonlite)
  library(httr2)
  library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
DATE_FROM  <- Sys.Date() - 365 * 5
DATE_TO    <- Sys.Date()

# ── 0. อ่าน credentials จาก env ────────────────────────────────────
fred_key <- Sys.getenv("FRED_API_KEY")
sa_json  <- Sys.getenv("GCP_SA_KEY")

if (fred_key == "") stop("FRED_API_KEY not set")
if (sa_json  == "") stop("GCP_SA_KEY not set")

fredr_set_key(fred_key)
sa <- fromJSON(sa_json)

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth (OAuth2 via service account JWT)
# ══════════════════════════════════════════════════════════════════

get_access_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss   = sa$client_email,
    scope = "https://www.googleapis.com/auth/datastore",
    aud   = "https://oauth2.googleapis.com/token",
    iat   = now,
    exp   = now + 3600
  )
  # clean private key (replace literal \n with real newlines)
  key_pem <- gsub("\\\\n", "\n", sa$private_key)
  jwt <- jwt_encode_sig(claim, key = key_pem)

  resp <- request("https://oauth2.googleapis.com/token") |>
    req_body_form(
      grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion  = jwt
    ) |>
    req_perform()

  resp_body_json(resp)$access_token
}

# ── Firestore write: 1 document = 1 series ─────────────────────────
# REST API: PATCH https://firestore.googleapis.com/v1/projects/{pid}/databases/(default)/documents/{collection}/{docId}

push_series <- function(token, doc_id, name, df) {
  # df: tibble(date, value)  →  Firestore array of maps
  points <- pmap(df, function(date, value) {
    list(mapValue = list(fields = list(
      d = list(stringValue = as.character(date)),
      v = list(doubleValue = value)
    )))
  })

  body <- list(fields = list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = points))
  ))

  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )

  resp <- request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()

  status <- resp_status(resp)
  if (status >= 300) {
    warning(sprintf("  ✗ %s: HTTP %d — %s", doc_id, status,
                    substr(resp_body_string(resp), 1, 200)))
    return(FALSE)
  }
  message(sprintf("  ✓ %s (%d points)", doc_id, nrow(df)))
  TRUE
}

# ══════════════════════════════════════════════════════════════════
#  PART 2 — Fetch data
# ══════════════════════════════════════════════════════════════════

# helper: yahoo via tidyquant → tibble(date, value)
fetch_yf <- function(ticker) {
  tryCatch({
    df <- tq_get(ticker, from = DATE_FROM, to = DATE_TO)
    if (is.null(df) || !is.data.frame(df)) stop("no data returned")
    result <- df |>
      select(date, value = close) |>
      drop_na(value) |>
      filter(is.finite(value))
    # ถ้าได้แค่ 1 row (current price only — เช่น SET sectors) ก็ยังเก็บได้
    if (nrow(result) == 0) stop("no valid rows")
    result
  }, error = function(e) {
    warning(sprintf("  yf SKIP %s: %s", ticker, e$message))
    tibble(date = as.Date(character()), value = numeric())
  })
}

fetch_fred <- function(series_id) {
  tryCatch({
    fredr(series_id = series_id, observation_start = DATE_FROM) |>
      select(date, value) |>
      drop_na()
  }, error = function(e) {
    warning(sprintf("  fred SKIP %s: %s", series_id, e$message))
    tibble(date = as.Date(character()), value = numeric())
  })
}

# ── catalog: doc_id → (source, ticker/series, display name) ────────
# doc_id ต้องไม่มีอักขระแปลกๆ (ใช้เป็น Firestore document id)
CATALOG <- tribble(
  ~doc_id,        ~src,    ~code,                   ~name,
  # US
  "SPX",          "yf",    "^GSPC",                 "S&P 500",
  "NASDAQ",       "yf",    "^IXIC",                 "NASDAQ",
  "VIX",          "yf",    "^VIX",                  "VIX",
  # EU indices
  "STOXX50",      "yf",    "^STOXX50E",             "Euro Stoxx 50",
  "DAX",          "yf",    "^GDAXI",                "DAX",
  "FTSE",         "yf",    "^FTSE",                 "FTSE 100",
  # Asia indices
  "SET",          "yf",    "^SET.BK",               "SET",
  "NIKKEI",       "yf",    "^N225",                 "Nikkei 225",
  "HSI",          "yf",    "^HSI",                  "Hang Seng",
  "KOSPI",        "yf",    "^KS11",                 "KOSPI",
  "NIFTY",        "yf",    "^NSEI",                 "Nifty 50",
  "IDX",          "yf",    "^JKSE",                 "IDX Composite",
  # FX
  "USDTHB",       "yf",    "THB=X",                 "USD/THB",
  "USDJPY",       "yf",    "JPY=X",                 "USD/JPY",
  "USDKRW",       "yf",    "KRW=X",                 "USD/KRW",
  "USDINR",       "yf",    "INR=X",                 "USD/INR",
  "USDIDR",       "yf",    "IDR=X",                 "USD/IDR",
  "EURUSD",       "yf",    "EURUSD=X",              "EUR/USD",
  # Commodities
  "WTI",          "yf",    "CL=F",                  "WTI Crude",
  "BRENT",        "yf",    "BZ=F",                  "Brent Crude",
  "GOLD",         "yf",    "GC=F",                  "Gold",
  "SILVER",       "yf",    "SI=F",                  "Silver",
  "COPPER",       "yf",    "HG=F",                  "Copper",
  "NATGAS",       "yf",    "NG=F",                  "Natural Gas",
  # SET Industry Group Indices (current price — accumulates daily)
  "SET_AGRO",     "yf",    "^AGRO.BK",              "SET Agro & Food",
  "SET_CONSUMP",  "yf",    "^CONSUMP.BK",            "SET Consumer Products",
  "SET_FINCIAL",  "yf",    "^FINCIAL.BK",            "SET Financials",
  "SET_INDUS",    "yf",    "^INDUS.BK",              "SET Industrials",
  "SET_PROPCON",  "yf",    "^PROPCON.BK",            "SET Property & Construction",
  "SET_RESOURC",  "yf",    "^RESOURC.BK",            "SET Resources",
  "SET_SERVICE",  "yf",    "^SERVICE.BK",            "SET Services",
  "SET_TECH",     "yf",    "^TECH.BK",               "SET Technology",
  # SET Sector Indices
  "SET_BANK",     "yf",    "^BANK.BK",               "SET Banking",
  "SET_ENERG",    "yf",    "^ENERG.BK",              "SET Energy & Utilities",
  "SET_FOOD",     "yf",    "^FOOD.BK",               "SET Food & Beverage",
  "SET_HELTH",    "yf",    "^HELTH.BK",              "SET Health Care",
  "SET_ICT",      "yf",    "^ICT.BK",                "SET ICT",
  "SET_INSUR",    "yf",    "^INSUR.BK",              "SET Insurance",
  "SET_PETRO",    "yf",    "^PETRO.BK",              "SET Petrochemicals",
  "SET_PROP",     "yf",    "^PROP.BK",               "SET Property Development",
  "SET_TRANS",    "yf",    "^TRANS.BK",              "SET Transportation",
  "SET_TOURISM",  "yf",    "^TOURISM.BK",            "SET Tourism & Leisure",
  "SET_COMM",     "yf",    "^COMM.BK",               "SET Commerce",
  "SET_CONMAT",   "yf",    "^CONMAT.BK",             "SET Construction Materials",
  "SET_STEEL",    "yf",    "^STEEL.BK",              "SET Steel & Metal",
  "SET_FIN",      "yf",    "^FIN.BK",                "SET Finance & Securities",
  "SET_AGRI",     "yf",    "^AGRI.BK",               "SET Agribusiness",
  # Magnificent 7
  "AAPL",         "yf",    "AAPL",                  "Apple",
  "MSFT",         "yf",    "MSFT",                  "Microsoft",
  "GOOGL",        "yf",    "GOOGL",                 "Alphabet",
  "AMZN",         "yf",    "AMZN",                  "Amazon",
  "NVDA",         "yf",    "NVDA",                  "NVIDIA",
  "META",         "yf",    "META",                  "Meta",
  "TSLA",         "yf",    "TSLA",                  "Tesla",
  # Crypto
  "BTC",          "yf",    "BTC-USD",               "Bitcoin",
  # FRED macro
  "FEDFUNDS",     "fred",  "FEDFUNDS",              "Fed Funds Rate",
  "CPI",          "fred",  "CPIAUCSL",              "US CPI (index)",
  "CORECPI",      "fred",  "CPILFESL",              "US Core CPI (index)",
  "DGS2",         "fred",  "DGS2",                  "2Y Treasury",
  "DGS10",        "fred",  "DGS10",                 "10Y Treasury",
  "UNRATE",       "fred",  "UNRATE",                "US Unemployment",
  "ECBRATE",      "fred",  "ECBDFR",                "ECB Rate",
  "EUCPI",        "fred",  "CP0000EZ17M086NEST",    "EU CPI (index)"
)

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Main
# ══════════════════════════════════════════════════════════════════

message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Fetching + pushing ", nrow(CATALOG), " series...")

ok_count <- 0
for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i, ]
  df <- if (row$src == "yf") fetch_yf(row$code) else fetch_fred(row$code)

  if (nrow(df) == 0) {
    warning(sprintf("  ⊘ %s: no data, skip push", row$doc_id))
    next
  }

  # ลด payload — เก็บ weekly สำหรับ daily data ที่ยาวมาก (ประหยัด Firestore)
  if (nrow(df) > 400) {
    df <- df |>
      mutate(wk = floor_date(date, "week")) |>
      group_by(wk) |>
      slice_tail(n = 1) |>
      ungroup() |>
      select(date, value)
  }

  if (push_series(token, row$doc_id, row$name, df)) ok_count <- ok_count + 1
  Sys.sleep(0.2)  # gentle on API
}

# ── meta document: last update timestamp ───────────────────────────
push_meta <- function(token) {
  body <- list(fields = list(
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    count   = list(integerValue = as.character(ok_count))
  ))
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/status",
    PROJECT_ID
  )
  request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
}
push_meta(token)

message(sprintf("\n✓ Done — %d/%d series pushed at %s",
                ok_count, nrow(CATALOG), Sys.time()))
