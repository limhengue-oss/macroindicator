# ══════════════════════════════════════════════════════════════════
#  push_oilfund_backfill.R
#  Push ข้อมูล workfile/offo_parsed.csv (ฐานะกองทุนน้ำมันย้อนหลัง) ขึ้น Firestore
#  ครั้งเดียว แล้วตั้ง meta/oilfund_status.last_date ให้ fetch_eppo.R
#  scrape ต่อจากจุดนี้ทุกวัน
#  รัน: Rscript push_oilfund_backfill.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(readr); library(purrr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
CSV_PATH   <- "workfile/offo_parsed.csv"

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

get_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(iss=sa$client_email,
    scope="https://www.googleapis.com/auth/datastore",
    aud="https://oauth2.googleapis.com/token", iat=now, exp=now+3600)
  jwt <- jwt_encode_sig(claim, key=gsub("\\\\n","\n",sa$private_key))
  resp_body_json(
    request("https://oauth2.googleapis.com/token") |>
      req_body_form(grant_type="urn:ietf:params:oauth:grant-type:jwt-bearer",
                    assertion=jwt) |> req_perform()
  )$access_token
}

upsert_series <- function(token, doc_id, name, new_df) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )
  pts <- pmap(new_df, function(date, value) {
    list(mapValue=list(fields=list(
      d=list(stringValue=as.character(date)),
      v=list(doubleValue=value)
    )))
  })
  body <- list(fields=list(
    name    = list(stringValue=name),
    updated = list(stringValue=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC")),
    data    = list(arrayValue=list(values=pts))
  ))
  resp <- request(url) |> req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  if (resp_status(resp) >= 300) {
    warning(sprintf("  ✗ %s HTTP %d", doc_id, resp_status(resp)))
    return(FALSE)
  }
  message(sprintf("  ✓ %s (%d pts)", doc_id, nrow(new_df)))
  TRUE
}

update_meta_last_date <- function(token, latest_date) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/oilfund_status",
    PROJECT_ID
  )
  body <- list(fields=list(
    last_date = list(stringValue=as.character(latest_date)),
    updated   = list(stringValue=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC"))
  ))
  r <- request(url) |> req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  if (resp_status(r) < 300) message(sprintf("  ✓ meta/oilfund_status.last_date → %s", latest_date))
  else warning(sprintf("  ✗ meta patch HTTP %d", resp_status(r)))
}

# ── Main ──────────────────────────────────────────────────────────
message("── Reading ", CSV_PATH)
df <- read_csv(CSV_PATH, col_types = cols(
  filename = col_character(), year = col_character(), date = col_date(),
  net_oil = col_double(), net_lpg = col_double(), net_total = col_double()
))
df <- df |> filter(!is.na(date)) |> arrange(date) |> distinct(date, .keep_all = TRUE)
message(sprintf("  %d rows, %s → %s", nrow(df), min(df$date), max(df$date)))

message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

series_map <- list(
  net_oil   = list(doc_id="OFFO_OILFUND_NET_OIL",   name="OFFO Oil Fund — Net Oil (net_oil)"),
  net_lpg   = list(doc_id="OFFO_OILFUND_NET_LPG",   name="OFFO Oil Fund — Net LPG (net_lpg)"),
  net_total = list(doc_id="OFFO_OILFUND_NET_TOTAL", name="OFFO Oil Fund — Net Total (net_total)")
)

for (field in names(series_map)) {
  s <- series_map[[field]]
  df_s <- df |> select(date, value = all_of(field)) |> filter(!is.na(value), is.finite(value))
  upsert_series(token, s$doc_id, s$name, df_s)
}

update_meta_last_date(token, max(df$date))

message("\n✓ Backfill done")
