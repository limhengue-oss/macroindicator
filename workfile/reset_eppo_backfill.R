# ══════════════════════════════════════════════════════════════════
#  reset_eppo_backfill.R
#  1) ลบ EPPO_* docs ทั้งหมดใน Firestore
#  2) Backfill ใหม่จาก eppo_backfill.csv
#  3) เขียน meta/eppo_status
#
#  รัน: Rscript reset_eppo_backfill.R
#  ต้องมี: GCP_SA_KEY (env var), eppo_backfill.csv (ใน working dir)
# ══════════════════════════════════════════════════════════════════

setwd("C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator/workfile")

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(stringr); library(purrr); library(readr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
CSV_FILE   <- "eppo_backfill.csv"

ALL_FIELDS <- c("EX_REFIN","EXCISE_TAX","M_TAX","OIL_FUND","CONSV_FUND",
                "VAT_WS","MARKETING_MARGIN","VAT_MM","RETAIL","WHOLESALE","EX_RATE")

make_doc_id <- function(base_product, field) {
  p <- base_product |>
    str_replace_all("[^A-Za-z0-9]+", "_") |>
    str_replace_all("_+", "_") |>
    str_remove("^_|_$") |>
    toupper()
  paste0("EPPO_", p, "_", field)
}

# ── Auth ──────────────────────────────────────────────────────────
sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

get_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss = sa$client_email,
    scope = "https://www.googleapis.com/auth/datastore",
    aud = "https://oauth2.googleapis.com/token",
    iat = now, exp = now + 3600
  )
  jwt <- jwt_encode_sig(claim, key = gsub("\\\\n", "\n", sa$private_key))
  resp_body_json(
    request("https://oauth2.googleapis.com/token") |>
      req_body_form(grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                    assertion = jwt) |>
      req_perform()
  )$access_token
}

fs_list_docs <- function(token, collection) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s?pageSize=300",
    PROJECT_ID, collection
  )
  all_names <- c()
  page_token <- NULL
  repeat {
    req <- request(url)
    if (!is.null(page_token)) req <- req |> req_url_query(pageToken = page_token)
    r <- req |>
      req_auth_bearer_token(token) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(r) != 200) break
    d <- resp_body_json(r)
    if (is.null(d$documents)) break
    names <- map_chr(d$documents, \(doc) basename(doc$name))
    all_names <- c(all_names, names)
    if (is.null(d$nextPageToken)) break
    page_token <- d$nextPageToken
  }
  all_names
}

fs_delete_doc <- function(token, collection, doc_id) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, collection, doc_id
  )
  r <- request(url) |>
    req_method("DELETE") |>
    req_auth_bearer_token(token) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  resp_status(r)
}

fs_put <- function(token, collection, doc_id, body) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, collection, doc_id
  )
  r <- request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  resp_status(r)
}

# ── Step 1: Auth ────────────────────────────────────────────────────
message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

# ── Step 2: ลบ EPPO_* docs ทั้งหมด ──────────────────────────────────
message("── Listing existing docs...")
all_docs  <- fs_list_docs(token, COLLECTION)
eppo_docs <- all_docs[str_starts(all_docs, "EPPO_")]
message(sprintf("  found %d EPPO_* docs to delete", length(eppo_docs)))

if (length(eppo_docs) > 0) {
  for (doc_id in eppo_docs) {
    status <- fs_delete_doc(token, COLLECTION, doc_id)
    if (status < 300) {
      message(sprintf("  ✓ deleted %s", doc_id))
    } else {
      message(sprintf("  ✗ HTTP %d deleting %s", status, doc_id))
    }
  }
}

# ลบ meta/eppo_status เก่าด้วย (ถ้ามี)
fs_delete_doc(token, "meta", "eppo_status")
message("  ✓ cleared meta/eppo_status (if existed)")

# ── Step 3: อ่าน CSV ─────────────────────────────────────────────────
message(sprintf("── Reading %s...", CSV_FILE))
if (!file.exists(CSV_FILE)) stop("ไม่พบไฟล์ ", CSV_FILE, " ใน working dir")

df <- read_csv(CSV_FILE, show_col_types = FALSE) |>
  select(-1)  # ตัด index column ตัวแรกออก

message(sprintf("  %d rows, %d dates, products: %s",
                nrow(df), n_distinct(df$DATE),
                paste(sort(unique(df$BASE_PRODUCT)), collapse = ", ")))

# ── Step 4: Push แต่ละ series ────────────────────────────────────────
message("── Pushing series to Firestore...")
ok <- 0

for (base in unique(df$BASE_PRODUCT)) {
  df_prod <- df |>
    filter(BASE_PRODUCT == base) |>
    arrange(DATE) |>
    distinct(DATE, .keep_all = TRUE)

  for (field in ALL_FIELDS) {
    if (!field %in% names(df_prod)) next

    df_series <- df_prod |>
      select(date = DATE, value = all_of(field)) |>
      filter(!is.na(value)) |>
      mutate(value = as.numeric(value)) |>
      filter(!is.na(value), is.finite(value)) |>
      distinct(date, .keep_all = TRUE) |>
      arrange(date)

    if (nrow(df_series) == 0) next

    doc_id <- make_doc_id(base, field)
    label  <- paste0("EPPO ", base, " — ", field)

    points <- pmap(df_series, function(date, value) {
      list(mapValue = list(fields = list(
        d = list(stringValue = as.character(date)),
        v = list(doubleValue = value)
      )))
    })

    body <- list(fields = list(
      name    = list(stringValue = label),
      updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
      data    = list(arrayValue = list(values = points))
    ))

    status <- fs_put(token, COLLECTION, doc_id, body)
    if (status < 300) {
      message(sprintf("  ✓ %s (%d pts)", doc_id, nrow(df_series)))
      ok <- ok + 1
    } else {
      message(sprintf("  ✗ HTTP %d %s", status, doc_id))
    }
    Sys.sleep(0.1)
  }
}

message(sprintf("── Pushed %d series", ok))

# ── Step 5: เขียน meta/eppo_status ───────────────────────────────────
message("── Writing meta/eppo_status...")
last_date      <- as.character(max(as.Date(df$DATE), na.rm = TRUE))
meta_products  <- sort(unique(df$BASE_PRODUCT))
meta_fields    <- ALL_FIELDS

body <- list(fields = list(
  last_date = list(stringValue = last_date),
  fields    = list(arrayValue = list(
    values = map(meta_fields, \(f) list(stringValue = f))
  )),
  products  = list(arrayValue = list(
    values = map(meta_products, \(p) list(stringValue = p))
  )),
  updated   = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
))

status <- fs_put(token, "meta", "eppo_status", body)
if (status < 300) {
  message(sprintf("✓ meta/eppo_status written (last_date = %s)", last_date))
} else {
  stop(sprintf("✗ HTTP %d writing meta doc", status))
}

message(sprintf("\n✓ Reset + backfill complete — %d series pushed, last_date = %s", ok, last_date))
