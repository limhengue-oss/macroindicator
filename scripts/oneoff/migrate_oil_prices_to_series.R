# ══════════════════════════════════════════════════════════════════
#  migrate_oil_prices_to_series.R
#  ย้ายข้อมูลจาก collection `oil_prices` (1 doc/วัน, field ULG95_SG/DIESEL_SG/
#  DUBAI) เข้า collection `series` (1 doc/series, schema {name,updated,
#  data:[{d,v}]} เดียวกับ EPPO/BOT/ฯลฯ) — doc id ปลายทาง: ULG95_SG, DIESEL_SG,
#  DUBAI (ดู functions/index.js ตัวใหม่ที่เขียนตรงเข้า series schema นี้แล้ว
#  ตั้งแต่ตอน migrate — สคริปต์นี้ย้ายแค่ข้อมูลเก่าที่ backfill ไว้ก่อนแก้โค้ด)
#
#  ไม่ลบ collection `oil_prices` เดิม — เก็บไว้เป็น backup เผื่อ migrate พลาด
#  (ลบเองทีหลังได้จาก Firebase Console เมื่อมั่นใจว่า series/ULG95_SG ฯลฯ
#  ถูกต้องครบแล้ว)
#
#  one-off script — รันครั้งเดียว
#  รัน (จาก repo root): Rscript scripts/oneoff/migrate_oil_prices_to_series.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(purrr)
})

PROJECT_ID <- "macroindicator-6b265"

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

# ── อ่านทั้ง collection oil_prices แบบ paginate ─────────────────────
fetch_all_oil_prices <- function(token) {
  base_url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/oil_prices",
    PROJECT_ID
  )
  rows <- list()
  page_token <- NULL
  repeat {
    q <- list(pageSize = 300)
    if (!is.null(page_token)) q$pageToken <- page_token
    resp <- request(base_url) |> req_url_query(!!!q) |>
      req_auth_bearer_token(token) |>
      req_error(is_error=\(r) FALSE) |> req_perform()
    if (resp_status(resp) != 200) stop("list oil_prices failed: HTTP ", resp_status(resp))
    body <- resp_body_json(resp)
    docs <- body$documents
    if (is.null(docs)) break
    for (d in docs) {
      date <- basename(d$name)
      f <- d$fields
      rows[[length(rows)+1]] <- list(
        date = date,
        ULG95_SG = if (!is.null(f$ULG95_SG$doubleValue)) as.numeric(f$ULG95_SG$doubleValue) else NA_real_,
        DIESEL_SG = if (!is.null(f$DIESEL_SG$doubleValue)) as.numeric(f$DIESEL_SG$doubleValue) else NA_real_,
        DUBAI = if (!is.null(f$DUBAI$doubleValue)) as.numeric(f$DUBAI$doubleValue) else NA_real_
      )
    }
    page_token <- body$nextPageToken
    if (is.null(page_token)) break
  }
  bind_rows(rows)
}

# GET existing series/{docId} → merge (new overwrite existing on same date) →
# PATCH ด้วย updateMask จำกัดเฉพาะ name/updated/data (บทเรียนจาก
# second-brain: PATCH ไม่ระบุ updateMask = ทับทั้ง document)
upsert_series <- function(token, doc_id, name, new_df) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/series/%s",
    PROJECT_ID, doc_id
  )
  existing_df <- tryCatch({
    r <- request(url) |> req_auth_bearer_token(token) |>
      req_error(is_error=\(r) FALSE) |> req_perform()
    if (resp_status(r) == 200) {
      arr <- resp_body_json(r)$fields$data$arrayValue$values
      if (!is.null(arr)) {
        tibble(
          date  = map_chr(arr, \(v) v$mapValue$fields$d$stringValue),
          value = map_dbl(arr, \(v) v$mapValue$fields$v$doubleValue)
        )
      } else tibble(date=character(), value=numeric())
    } else tibble(date=character(), value=numeric())
  }, error=function(e) tibble(date=character(), value=numeric()))

  merged <- bind_rows(
    existing_df |> filter(!date %in% new_df$date),
    new_df
  ) |> arrange(date)

  pts <- pmap(merged, function(date, value) {
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
  resp <- request(url) |>
    req_url_query(`updateMask.fieldPaths`=c("name","updated","data"), .multi="explode") |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  if (resp_status(resp) >= 300) {
    warning(sprintf("  ✗ series/%s HTTP %d", doc_id, resp_status(resp)))
    return(FALSE)
  }
  message(sprintf("  ✓ series/%s (%d pts merged, %d total)", doc_id, nrow(new_df), nrow(merged)))
  TRUE
}

# ── Main ──────────────────────────────────────────────────────────
message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

message("── Reading oil_prices collection...")
df <- fetch_all_oil_prices(token)
message(sprintf("  %d docs", nrow(df)))

series_map <- list(
  ULG95_SG  = "PEIT — ULG 95 (S'pore)",
  DIESEL_SG = "PEIT — GO 0.001%S (S'pore Diesel)",
  DUBAI     = "PEIT — Dubai crude"
)

message("── Migrating to series/...")
for (field in names(series_map)) {
  df_s <- df |> select(date, value = all_of(field)) |>
    filter(!is.na(value), is.finite(value)) |>
    distinct(date, .keep_all = TRUE)
  if (nrow(df_s) == 0) {
    message(sprintf("  · %s: no data, skip", field))
    next
  }
  upsert_series(token, field, series_map[[field]], df_s)
}

message("\n✓ Migration done — collection oil_prices เดิมยังอยู่ (ไม่ได้ลบ) เก็บไว้เป็น backup")
