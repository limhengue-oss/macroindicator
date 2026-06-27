# ══════════════════════════════════════════════════════════════════
#  eppo_backfill.R
#  1. ลบ EPPO docs เก่าทั้งหมดออกจาก Firestore
#  2. Backfill ใหม่จาก eppo_backfill.csv ใช้ PRODUCT_CLEAN เป็น doc_id
#
#  ตั้ง env ก่อนรัน:
#  Sys.setenv(GCP_SA_KEY = paste(readLines("path/to/sa.json"), collapse="\n"))
#  source("eppo_backfill.R")
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
  library(jose)
  library(dplyr)
  library(purrr)
  library(stringr)
  library(lubridate)
})

# ── Config ────────────────────────────────────────────────────────
CSV_PATH   <- "C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator/workfile/eppo_backfill.csv"
PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

FIELDS <- c("EX_REFIN","EXCISE_TAX","M_TAX","OIL_FUND","CONSV_FUND",
            "VAT_WS","MARKETING_MARGIN","VAT_MM","RETAIL","WHOLESALE","EX_RATE")
# ไม่เก็บ: DISCOUNT, OIL_FUND_2

# ── Credentials ───────────────────────────────────────────────────
sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

# ── Helpers ───────────────────────────────────────────────────────
make_doc_id <- function(base_product, field) {
  p <- base_product |>
    str_replace_all("[^A-Za-z0-9]+", "_") |>
    str_replace_all("_+", "_") |>
    str_remove("^_|_$") |>
    toupper()
  paste0("EPPO_", p, "_", field)
}

get_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss   = sa$client_email,
    sub   = sa$client_email,
    scope = "https://www.googleapis.com/auth/datastore",
    aud   = "https://oauth2.googleapis.com/token",
    iat   = now, exp = now + 3600
  )
  jwt <- jwt_encode_sig(claim, key = sa$private_key)
  resp <- request("https://oauth2.googleapis.com/token") |>
    req_body_form(grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                  assertion  = jwt) |>
    req_perform()
  resp_body_json(resp)$access_token
}

firestore_url <- function(doc_id = NULL) {
  base <- sprintf("https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s",
                  PROJECT_ID, COLLECTION)
  if (is.null(doc_id)) base else paste0(base, "/", doc_id)
}

# ── Step 1: ลบ EPPO docs เก่า ─────────────────────────────────────
message("── Step 1: Deleting old EPPO docs...")
token <- get_token(sa)

# list ทุก docs (อาจต้อง paginate ถ้ามีมากกว่า 300)
get_all_eppo_docs <- function(token) {
  all_names <- character(0)
  page_token <- NULL
  repeat {
    url <- paste0(firestore_url(), "?pageSize=300",
                  if (!is.null(page_token)) paste0("&pageToken=", page_token) else "")
    resp <- request(url) |>
      req_auth_bearer_token(token) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    d <- resp_body_json(resp)
    docs <- d$documents
    if (!is.null(docs)) {
      names_batch <- map_chr(docs, "name")
      eppo <- names_batch[grepl("/EPPO_", names_batch)]
      all_names <- c(all_names, eppo)
    }
    page_token <- d$nextPageToken
    if (is.null(page_token) || length(page_token) == 0) break
  }
  all_names
}

eppo_docs <- get_all_eppo_docs(token)
message(sprintf("  Found %d EPPO docs to delete", length(eppo_docs)))

deleted <- 0
for (doc_name in eppo_docs) {
  doc_id <- basename(doc_name)
  url    <- firestore_url(doc_id)
  resp   <- request(url) |>
    req_method("DELETE") |>
    req_auth_bearer_token(token) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(resp) %in% c(200, 204)) {
    deleted <- deleted + 1
  } else {
    warning(sprintf("  ✗ delete %s: HTTP %d", doc_id, resp_status(resp)))
  }
  Sys.sleep(0.05)
}
message(sprintf("  ✓ Deleted %d docs", deleted))

# refresh token หลัง delete เสร็จ (อาจใช้เวลานาน)
token <- get_token(sa)

# ── Step 2: Load + clean CSV ──────────────────────────────────────
message("\n── Step 2: Loading CSV...")
df_raw <- read.csv(CSV_PATH, stringsAsFactors = FALSE, na.strings = c("NA","","N/A"))

df <- df_raw |>
  mutate(
    date_parsed = as.Date(DATE),
    date_str    = as.character(date_parsed)
  ) |>
  filter(!is.na(date_parsed), !is.na(PRODUCT_CLEAN), PRODUCT_CLEAN != "") |>
  arrange(date_str)

message(sprintf("  %d rows | %d products | %s → %s",
                nrow(df),
                n_distinct(df$PRODUCT_CLEAN),
                min(df$date_str), max(df$date_str)))
cat("  Products:", paste(sort(unique(df$PRODUCT_CLEAN)), collapse=", "), "\n")

# ── Step 3: Push ──────────────────────────────────────────────────
message("\n── Step 3: Pushing to Firestore...")

push_series <- function(token, doc_id, name, df_series) {
  points <- pmap(df_series, function(date, value) {
    list(mapValue = list(fields = list(
      d = list(stringValue = date),
      v = list(doubleValue  = value)
    )))
  })
  body <- list(fields = list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz="UTC")),
    data    = list(arrayValue = list(values = points))
  ))
  resp <- request(firestore_url(doc_id)) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  status <- resp_status(resp)
  if (status >= 300) { warning(sprintf("  ✗ %s HTTP %d", doc_id, status)); return(FALSE) }
  TRUE
}

# group by BASE_PRODUCT — แต่ละวันมีราคาเดียวต่อ BASE_PRODUCT เสมอ
base_products <- sort(unique(df$BASE_PRODUCT))
ok <- 0; skip <- 0

for (base in base_products) {
  df_base <- df |>
    filter(BASE_PRODUCT == base) |>
    arrange(date_str) |>
    distinct(date_str, .keep_all = TRUE)  # กัน duplicate (ไม่ควรมี แต่ safety)
  
  message(sprintf("\n  [%s] %d rows (products: %s)",
                  base, nrow(df_base),
                  paste(unique(df_base$PRODUCT_CLEAN), collapse=" + ")))
  
  # refresh token ทุก base_product เผื่อหมดอายุ
  token <- get_token(sa)
  
  for (field in FIELDS) {
    if (!field %in% names(df_base)) { skip <- skip + 1; next }
    
    df_series <- df_base |>
      select(date = date_str, value = all_of(field)) |>
      mutate(value = suppressWarnings(as.numeric(value))) |>
      filter(!is.na(value), is.finite(value)) |>
      distinct(date, .keep_all = TRUE) |>
      arrange(date)
    
    if (nrow(df_series) == 0) { skip <- skip + 1; next }
    
    doc_id <- make_doc_id(base, field)
    label  <- paste0("EPPO ", base, " — ", field)
    
    if (push_series(token, doc_id, label, df_series)) {
      ok <- ok + 1
      message(sprintf("    ✓ %s (%d pts)", doc_id, nrow(df_series)))
    }
    Sys.sleep(0.15)
  }
}

message(sprintf("\n✓ Done — pushed %d series, skipped %d", ok, skip))