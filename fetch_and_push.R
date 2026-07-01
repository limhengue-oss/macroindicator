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

PROJECT_ID   <- "macroindicator-6b265"
COLLECTION   <- "series"
DEFAULT_FROM <- as.Date("1990-01-01")   # ใช้เมื่อ series ใหม่ ไม่เคยมีใน meta
DAILY_FROM   <- as.Date("1990-01-01")   # เก็บ daily ทั้งหมด ไม่ thin
DATE_TO      <- Sys.Date()

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

`%||%` <- function(x, y) if (is.null(x) || length(x)==0 || is.na(x)) y else x

push_series <- function(token, doc_id, name, df, is_incremental, meta = NULL) {
  # df: tibble(date, value)  →  Firestore array of maps
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

  # ถ้าเป็น incremental update — GET existing แล้ว append
  all_points <- new_points
  if (is_incremental) {
    existing_points <- tryCatch({
      r <- request(url) |>
        req_auth_bearer_token(token) |>
        req_error(is_error = \(r) FALSE) |>
        req_perform()
      if (resp_status(r) == 200) {
        d   <- resp_body_json(r)
        arr <- d$fields$data$arrayValue$values
        if (!is.null(arr)) arr else list()
      } else list()
    }, error = function(e) list())
    all_points <- c(existing_points, new_points)
  }

  fields <- list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = all_points))
  )

  # เพิ่ม meta field ถ้ามี
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
  message(sprintf("  ✓ %s (+%d new points)", doc_id, nrow(df)))
  TRUE
}


# ══════════════════════════════════════════════════════════════════
#  PART 2 — Fetch data
# ══════════════════════════════════════════════════════════════════

# helper: yahoo via tidyquant → tibble(date, value)
fetch_yf <- function(ticker, from) {
  tryCatch({
    df <- tq_get(ticker, from = from, to = DATE_TO)
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

fetch_meta_yf <- function(ticker) {
  tryCatch({
    info <- tq_get(ticker, get = "stock.prices", from = Sys.Date()-1) |> head(1)
    # ดึง extra info ผ่าน quantmod
    env <- new.env()
    suppressWarnings(quantmod::getQuote(ticker, src = "yahoo", what = quantmod::yahooQF(
      c("Name", "Currency", "Last Trade (Price Only)")
    ), env = env))
    q <- get(ls(env)[1], envir = env)
    list(
      fullName = tryCatch(as.character(q[,"Name"]), error=function(e) ticker),
      currency = tryCatch(as.character(q[,"Currency"]), error=function(e) ""),
      unit     = "",
      freq     = "Daily",
      source   = paste0("Yahoo Finance (", ticker, ")")
    )
  }, error = function(e) {
    list(fullName=ticker, currency="", unit="", freq="Daily",
         source=paste0("Yahoo Finance (", ticker, ")"))
  })
}

fetch_meta_fred <- function(series_id) {
  tryCatch({
    s <- fredr_series(series_id = series_id)
    list(
      fullName = s$title,
      currency = "",
      unit     = s$units_short %||% s$units %||% "",
      freq     = s$frequency_short %||% s$frequency %||% "",
      source   = paste0("FRED (", series_id, ")")
    )
  }, error = function(e) {
    list(fullName=series_id, currency="", unit="", freq="",
         source=paste0("FRED (", series_id, ")"))
  })
}

fetch_fred <- function(series_id, from) {
  tryCatch({
    fredr(series_id = series_id, observation_start = from) |>
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
#  PART 2b — Meta status helpers
# ══════════════════════════════════════════════════════════════════
push_meta <- function(token, ok_count) {
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

# ── meta/fetch_status: per-series last_date ─────────────────────────
get_fetch_status <- function(token) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/fetch_status",
    PROJECT_ID
  )
  r <- request(url) |>
    req_auth_bearer_token(token) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(r) != 200) return(list())  # ไม่มี doc — ทุก series เป็น full backfill

  d      <- resp_body_json(r)
  fields <- d$fields
  if (is.null(fields)) return(list())

  out <- list()
  for (k in names(fields)) {
    v <- fields[[k]]$stringValue
    if (!is.null(v)) out[[k]] <- as.Date(v)
  }
  out
}

push_fetch_status <- function(token, status_list) {
  # status_list: named list doc_id -> Date
  fields <- list()
  for (k in names(status_list)) {
    fields[[k]] <- list(stringValue = as.character(status_list[[k]]))
  }
  body <- list(fields = fields)
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/fetch_status",
    PROJECT_ID
  )
  r <- request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  resp_status(r)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Main
# ══════════════════════════════════════════════════════════════════

message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Reading meta/fetch_status...")
fetch_status <- get_fetch_status(token)
message(sprintf("  %d series have prior last_date", length(fetch_status)))

message("── Fetching + pushing ", nrow(CATALOG), " series...")

ok_count <- 0
new_status <- fetch_status   # จะอัพเดททีละ series ที่ push สำเร็จ

for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i, ]
  is_incremental <- !is.null(fetch_status[[row$doc_id]])
  from <- if (is_incremental) fetch_status[[row$doc_id]] + 1 else DEFAULT_FROM

  df <- if (row$src == "yf") fetch_yf(row$code, from) else fetch_fred(row$code, from)

  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no new data since %s", row$doc_id, from))
    next
  }

  # เก็บ daily ตั้งแต่ DAILY_FROM เป็นต้นไป, ก่อนหน้านั้น thin เป็น weekly
  df_recent <- df |> filter(date >= DAILY_FROM)
  df_old    <- df |> filter(date <  DAILY_FROM)

  if (nrow(df_old) > 0) {
    df_old <- df_old |>
      mutate(wk = floor_date(date, "week")) |>
      group_by(wk) |>
      slice_tail(n = 1) |>
      ungroup() |>
      select(date, value)
  }

  df <- bind_rows(df_old, df_recent) |> arrange(date)

  # fetch meta เฉพาะตอน full backfill ครั้งแรก
  meta <- if (!is_incremental) {
    message(sprintf("  fetching meta for %s...", row$doc_id))
    if (row$src == "yf") fetch_meta_yf(row$code) else fetch_meta_fred(row$code)
  } else NULL

  if (push_series(token, row$doc_id, row$name, df, is_incremental, meta)) {
    ok_count <- ok_count + 1
    new_status[[row$doc_id]] <- max(df$date, na.rm = TRUE)
  }
  Sys.sleep(0.2)
}

push_meta(token, ok_count)

message("── Updating meta/fetch_status...")
status_code <- push_fetch_status(token, new_status)
if (status_code < 300) {
  message("  ✓ fetch_status updated")
} else {
  message(sprintf("  ✗ HTTP %d updating fetch_status", status_code))
}

message(sprintf("\n✓ Done — %d/%d series pushed at %s",
                ok_count, nrow(CATALOG), Sys.time()))
