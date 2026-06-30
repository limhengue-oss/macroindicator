# ══════════════════════════════════════════════════════════════════
#  reset_series_for_daily.R
#  1) ลบทุก doc ใน collection "series" (ยกเว้น EPPO_* ที่จัดการแยกแล้ว)
#  2) ลบ meta/fetch_status เก่า
#  หลังรันนี้แล้ว ให้รัน fetch_and_push.R ตามปกติ — จะ full backfill
#  daily ทั้งหมดใหม่ (เพราะ meta/fetch_status ว่าง)
#
#  รัน: Rscript reset_series_for_daily.R
#  ต้องมี: GCP_SA_KEY (env var)
# ══════════════════════════════════════════════════════════════════

setwd("C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator/workfile")


Sys.setenv(GCP_SA_KEY = paste(readLines("C:/Users/limhe/OneDrive/Desktop/Rdevclaude/macroindicator-6b265-firebase-adminsdk-fbsvc-3a4c23a65a.json"), collapse = "\n"))


suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose); library(purrr); library(stringr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

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

# ── Step 1: Auth ────────────────────────────────────────────────────
message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

# ── Step 2: ลบ series docs (ยกเว้น EPPO_*) ──────────────────────────
message("── Listing existing series docs...")
all_docs    <- fs_list_docs(token, COLLECTION)
target_docs <- all_docs[!str_starts(all_docs, "EPPO_")]
eppo_count  <- length(all_docs) - length(target_docs)

message(sprintf("  found %d docs total (%d EPPO_* kept, %d to delete)",
                length(all_docs), eppo_count, length(target_docs)))

if (length(target_docs) > 0) {
  for (doc_id in target_docs) {
    status <- fs_delete_doc(token, COLLECTION, doc_id)
    if (status < 300) {
      message(sprintf("  ✓ deleted %s", doc_id))
    } else {
      message(sprintf("  ✗ HTTP %d deleting %s", status, doc_id))
    }
  }
}

# ── Step 3: ลบ meta/fetch_status ────────────────────────────────────
status <- fs_delete_doc(token, "meta", "fetch_status")
message(sprintf("  ✓ cleared meta/fetch_status (HTTP %d, 404 = already empty)", status))

message("\n✓ Reset complete — รัน fetch_and_push.R ต่อเพื่อ full daily backfill")
