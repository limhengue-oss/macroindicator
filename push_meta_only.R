# ══════════════════════════════════════════════════════════════════
#  push_meta_only.R
#  ดึง metadata จาก Yahoo/FRED แล้ว PATCH ขึ้น Firestore
#  โดยไม่แตะ data array เดิม
#
#  รัน: Rscript push_meta_only.R
#  ต้องมี: GCP_SA_KEY, FRED_API_KEY (env vars)
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(tidyquant); library(fredr)
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(purrr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json  <- Sys.getenv("GCP_SA_KEY")
fred_key <- Sys.getenv("FRED_API_KEY")
if (sa_json  == "") stop("GCP_SA_KEY not set")
if (fred_key == "") stop("FRED_API_KEY not set")

fredr_set_key(fred_key)
sa <- fromJSON(sa_json)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

# ── Auth ──────────────────────────────────────────────────────────
get_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss = sa$client_email, scope = "https://www.googleapis.com/auth/datastore",
    aud = "https://oauth2.googleapis.com/token", iat = now, exp = now + 3600
  )
  jwt <- jwt_encode_sig(claim, key = gsub("\\\\n", "\n", sa$private_key))
  resp_body_json(
    request("https://oauth2.googleapis.com/token") |>
      req_body_form(grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion = jwt) |>
      req_perform()
  )$access_token
}

# ── PATCH เฉพาะ meta field (ไม่แตะ data) ─────────────────────────
patch_meta <- function(token, doc_id, meta) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s?updateMask.fieldPaths=meta",
    PROJECT_ID, COLLECTION, doc_id
  )
  body <- list(fields = list(
    meta = list(mapValue = list(fields = list(
      fullName = list(stringValue = meta$fullName %||% ""),
      currency = list(stringValue = meta$currency %||% ""),
      unit     = list(stringValue = meta$unit     %||% ""),
      freq     = list(stringValue = meta$freq     %||% ""),
      source   = list(stringValue = meta$source   %||% "")
    )))
  ))
  r <- request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  resp_status(r)
}

# ── Fetch metadata ─────────────────────────────────────────────────
fetch_meta_yf <- function(ticker) {
  tryCatch({
    env <- new.env()
    suppressWarnings(quantmod::getQuote(ticker, src = "yahoo",
      what = quantmod::yahooQF(c("Name", "Currency")), env = env))
    q <- get(ls(env)[1], envir = env)
    list(
      fullName = tryCatch(as.character(q[,"Name"]),     error = function(e) ticker),
      currency = tryCatch(as.character(q[,"Currency"]), error = function(e) ""),
      unit = "", freq = "Daily",
      source = paste0("Yahoo Finance (", ticker, ")")
    )
  }, error = function(e) {
    list(fullName = ticker, currency = "", unit = "", freq = "Daily",
         source = paste0("Yahoo Finance (", ticker, ")"))
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
    list(fullName = series_id, currency = "", unit = "", freq = "",
         source = paste0("FRED (", series_id, ")"))
  })
}

# ── CATALOG (คัดลอกจาก fetch_and_push.R) ─────────────────────────
CATALOG <- tribble(
  ~doc_id,        ~src,    ~code,
  "SPX",          "yf",    "^GSPC",
  "NASDAQ",       "yf",    "^IXIC",
  "VIX",          "yf",    "^VIX",
  "STOXX50",      "yf",    "^STOXX50E",
  "DAX",          "yf",    "^GDAXI",
  "FTSE",         "yf",    "^FTSE",
  "SET",          "yf",    "^SET.BK",
  "NIKKEI",       "yf",    "^N225",
  "HSI",          "yf",    "^HSI",
  "KOSPI",        "yf",    "^KS11",
  "NIFTY",        "yf",    "^NSEI",
  "IDX",          "yf",    "^JKSE",
  "USDTHB",       "yf",    "THB=X",
  "USDJPY",       "yf",    "JPY=X",
  "USDKRW",       "yf",    "KRW=X",
  "USDINR",       "yf",    "INR=X",
  "USDIDR",       "yf",    "IDR=X",
  "EURUSD",       "yf",    "EURUSD=X",
  "WTI",          "yf",    "CL=F",
  "BRENT",        "yf",    "BZ=F",
  "GOLD",         "yf",    "GC=F",
  "SILVER",       "yf",    "SI=F",
  "COPPER",       "yf",    "HG=F",
  "NATGAS",       "yf",    "NG=F",
  "SET_AGRO",     "yf",    "^AGRO.BK",
  "SET_CONSUMP",  "yf",    "^CONSUMP.BK",
  "SET_FINCIAL",  "yf",    "^FINCIAL.BK",
  "SET_INDUS",    "yf",    "^INDUS.BK",
  "SET_PROPCON",  "yf",    "^PROPCON.BK",
  "SET_RESOURC",  "yf",    "^RESOURC.BK",
  "SET_SERVICE",  "yf",    "^SERVICE.BK",
  "SET_TECH",     "yf",    "^TECH.BK",
  "SET_BANK",     "yf",    "^BANK.BK",
  "SET_ENERG",    "yf",    "^ENERG.BK",
  "SET_FOOD",     "yf",    "^FOOD.BK",
  "SET_HELTH",    "yf",    "^HELTH.BK",
  "SET_ICT",      "yf",    "^ICT.BK",
  "SET_INSUR",    "yf",    "^INSUR.BK",
  "SET_PETRO",    "yf",    "^PETRO.BK",
  "SET_PROP",     "yf",    "^PROP.BK",
  "SET_TRANS",    "yf",    "^TRANS.BK",
  "SET_TOURISM",  "yf",    "^TOURISM.BK",
  "SET_COMM",     "yf",    "^COMM.BK",
  "SET_CONMAT",   "yf",    "^CONMAT.BK",
  "SET_STEEL",    "yf",    "^STEEL.BK",
  "SET_FIN",      "yf",    "^FIN.BK",
  "SET_AGRI",     "yf",    "^AGRI.BK",
  "AAPL",         "yf",    "AAPL",
  "MSFT",         "yf",    "MSFT",
  "GOOGL",        "yf",    "GOOGL",
  "AMZN",         "yf",    "AMZN",
  "NVDA",         "yf",    "NVDA",
  "META",         "yf",    "META",
  "TSLA",         "yf",    "TSLA",
  "BTC",          "yf",    "BTC-USD",
  "FEDFUNDS",     "fred",  "FEDFUNDS",
  "CPI",          "fred",  "CPIAUCSL",
  "CORECPI",      "fred",  "CPILFESL",
  "DGS2",         "fred",  "DGS2",
  "DGS10",        "fred",  "DGS10",
  "UNRATE",       "fred",  "UNRATE",
  "ECBRATE",      "fred",  "ECBDFR",
  "EUCPI",        "fred",  "CP0000EZ17M086NEST"
)

# ── Main ──────────────────────────────────────────────────────────
message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

ok <- 0
for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i,]
  message(sprintf("  [%d/%d] %s...", i, nrow(CATALOG), row$doc_id))

  meta <- if (row$src == "yf") fetch_meta_yf(row$code) else fetch_meta_fred(row$code)
  status <- patch_meta(token, row$doc_id, meta)

  if (status < 300) {
    message(sprintf("    ✓ %s | %s | %s", meta$fullName, meta$unit, meta$source))
    ok <- ok + 1
  } else {
    message(sprintf("    ✗ HTTP %d", status))
  }
  Sys.sleep(0.15)
}

message(sprintf("\n✓ Done — %d/%d series updated", ok, nrow(CATALOG)))
