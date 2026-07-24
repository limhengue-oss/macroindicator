# ══════════════════════════════════════════════════════════════════
#  fetch_goldth.R
#  ดึงราคาทองคำแท่ง 96.5% ในไทย จาก API ของสมาคมค้าทองคำ (newgta.goldtraders.or.th)
#  → push ขึ้น Firestore
#
#  Endpoint (public, ไม่ต้อง API key, ไม่มี bot-check):
#    GET https://newgta.goldtraders.or.th/api/GoldPricesDaily/pricechanges
#        ?StartDate=YYYY-MM-DD&EndDate=YYYY-MM-DD
#  คืนค่าราคาทุกรอบที่ประกาศปรับ (หลายรอบ/วัน) ไม่ใช่ 1 จุด/วัน — เก็บเป็น
#  timeseries รายวันจึงเอาแค่ "ราคาปิด" ของแต่ละวัน (รอบล่าสุดของวันนั้น)
#
#  field ที่ใช้:
#    bL_BuyPrice / bL_SellPrice = ทองคำแท่ง 96.5% ราคารับซื้อ/ขายออก
#    (บาทต่อน้ำหนัก 1 บาท)
#
#  Environment variables ที่ต้องตั้ง:
#    GCP_SA_KEY — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_goldth.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
#
#  Backfill: ครั้งแรกดึงเต็มประวัติตั้งแต่ 2007-01-01 (จุดเริ่มต้นจริงของ
#  ข้อมูลใน API — เช็คแล้วว่าก่อนหน้านั้นไม่มี) แบ่งดึงทีละปีกัน timeout
#  จากนั้นรอบถัดๆ ไปดึงต่อจากวันล่าสุดที่มีอยู่แค่ช่วงสั้นๆ ทุกวัน
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(dplyr)
  library(purrr)
  library(tibble)
  library(lubridate)
  library(jsonlite)
  library(httr2)
  library(jose)
})

PROJECT_ID  <- "macroindicator-6b265"
COLLECTION  <- "series"
DATE_TO     <- Sys.Date()
DATA_START  <- as.Date("2007-01-01")  # ก่อนหน้านี้ API ไม่มีข้อมูล (เช็คแล้ว 2026-07-24)

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth + push (เหมือน fetch_thaibma.R)
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

dedup_sort_points <- function(pts) {
  if (length(pts) == 0) return(pts)
  dates <- map_chr(pts, \(p) p$mapValue$fields$d$stringValue)
  keep  <- !duplicated(dates, fromLast = TRUE)
  pts   <- pts[keep]
  dates <- dates[keep]
  pts[order(dates)]
}

push_series <- function(token, doc_id, name, df, is_incremental, meta = NULL) {
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

  all_points <- new_points
  if (is_incremental) {
    existing_points <- tryCatch({
      r <- request(url) |> req_auth_bearer_token(token) |>
        req_error(is_error = \(r) FALSE) |> req_perform()
      if (resp_status(r) == 200) {
        arr <- resp_body_json(r)$fields$data$arrayValue$values
        if (!is.null(arr)) arr else list()
      } else list()
    }, error = function(e) list())
    all_points <- dedup_sort_points(c(existing_points, new_points))
  }

  fields <- list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = all_points))
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
  message(sprintf("  ✓ %s (+%d new points)", doc_id, nrow(df)))
  TRUE
}

# ══════════════════════════════════════════════════════════════════
#  PART 2 — Gold Traders Association API client
# ══════════════════════════════════════════════════════════════════

fetch_goldth_range <- function(from, to) {
  tryCatch({
    resp <- request("https://newgta.goldtraders.or.th/api/GoldPricesDaily/pricechanges") |>
      req_url_query(StartDate = as.character(from), EndDate = as.character(to)) |>
      req_headers(`User-Agent` = "Mozilla/5.0 (compatible; macroindicator-bot/1.0)", Accept = "application/json") |>
      req_timeout(90) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))
    d <- resp_body_json(resp)
    # ช่วงที่ไม่มีข้อมูล (เช่น ก่อน 2007) API คืน object ห่อ {success,message,data}
    # แทนที่จะเป็น array ตรงๆ เหมือนช่วงที่มีข้อมูล — ต้องแกะให้ตรงกันก่อน
    if (!is.null(names(d)) && "data" %in% names(d)) d <- d$data
    if (length(d) == 0) return(tibble(datetime = character(), buy = double(), sell = double()))
    tibble(
      datetime = map_chr(d, \(x) x$asTime),
      buy      = map_dbl(d, \(x) x$bL_BuyPrice  %||% NA_real_),
      sell     = map_dbl(d, \(x) x$bL_SellPrice %||% NA_real_)
    )
  }, error = function(e) {
    warning(sprintf("  goldth SKIP %s..%s: %s", from, to, e$message))
    tibble(datetime = character(), buy = double(), sell = double())
  })
}

# แบ่งดึงเป็นรายปี กัน timeout (1 ปี ~10-15 วินาที, ทั้งช่วง 2007-ปัจจุบัน
# ทีเดียวเจอ 504 Gateway Timeout ตอนทดสอบจริง 2026-07-24)
fetch_goldth_full_history <- function(from, to) {
  years <- seq(year(from), year(to))
  dfs <- map(years, function(y) {
    y_from <- max(from, as.Date(sprintf("%d-01-01", y)))
    y_to   <- min(to,   as.Date(sprintf("%d-12-31", y)))
    message(sprintf("  ปี %d (%s..%s)...", y, y_from, y_to))
    df <- fetch_goldth_range(y_from, y_to)
    Sys.sleep(0.3)
    df
  })
  bind_rows(dfs)
}

# เอา "ราคาปิด" ของแต่ละวัน (รอบล่าสุดที่ประกาศในวันนั้น) — ทองคำแท่งมีการ
# ปรับราคาหลายรอบ/วัน ไม่เก็บทุก tick เพื่อให้เข้ากับ timeseries รายวันปกติ
to_daily_close <- function(raw_df, value_col) {
  raw_df |>
    mutate(date = as.Date(substr(datetime, 1, 10))) |>
    filter(!is.na(.data[[value_col]])) |>
    group_by(date) |>
    slice_max(datetime, n = 1, with_ties = FALSE) |>
    ungroup() |>
    transmute(date, value = .data[[value_col]]) |>
    arrange(date)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — fetch_status (incremental, namespace ร่วมกับ series อื่น)
# ══════════════════════════════════════════════════════════════════
get_fetch_status <- function(token) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/fetch_status",
    PROJECT_ID
  )
  r <- request(url) |> req_auth_bearer_token(token) |>
    req_error(is_error = \(r) FALSE) |> req_perform()
  if (resp_status(r) != 200) return(list())
  fields <- resp_body_json(r)$fields
  if (is.null(fields)) return(list())
  out <- list()
  for (k in names(fields)) {
    v <- fields[[k]]$stringValue
    if (!is.null(v)) out[[k]] <- as.Date(v)
  }
  out
}

push_fetch_status <- function(token, status_list) {
  fields <- list()
  for (k in names(status_list)) fields[[k]] <- list(stringValue = as.character(status_list[[k]]))
  body <- list(fields = fields)
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/fetch_status",
    PROJECT_ID
  )
  request(url) |> req_method("PATCH") |> req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |> req_perform()
}

# ══════════════════════════════════════════════════════════════════
#  PART 4 — Main
# ══════════════════════════════════════════════════════════════════
SERIES_DEF <- tribble(
  ~doc_id,          ~col,    ~label,
  "GOLDTH_BAR_BUY",  "buy",  "Thai Gold Bar 96.5% — Buy Price",
  "GOLDTH_BAR_SELL", "sell", "Thai Gold Bar 96.5% — Sell Price"
)

message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Reading meta/fetch_status...")
fetch_status <- get_fetch_status(token)

known_dates <- fetch_status[SERIES_DEF$doc_id]
known_dates <- known_dates[!sapply(known_dates, is.null)]
is_first_run <- length(known_dates) == 0
from <- if (is_first_run) DATA_START else min(unlist(known_dates)) |> as.Date() + 1

message(sprintf("── Fetching Thai gold bar prices from %s to %s...", from, DATE_TO))
raw <- if (is_first_run) fetch_goldth_full_history(from, DATE_TO) else fetch_goldth_range(from, DATE_TO)
message(sprintf("  %d price updates fetched", nrow(raw)))

ok_count <- 0
new_status <- fetch_status

for (i in seq_len(nrow(SERIES_DEF))) {
  row <- SERIES_DEF[i, ]
  is_incremental <- !is.null(fetch_status[[row$doc_id]])
  df <- to_daily_close(raw, row$col)
  series_from <- if (is_incremental) fetch_status[[row$doc_id]] + 1 else as.Date(-Inf)
  df <- df |> filter(date >= series_from)

  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no new data", row$doc_id))
    next
  }

  meta <- list(
    fullName = row$label,
    currency = "THB",
    unit     = "บาท/บาททองคำ (Baht per Baht-weight)",
    freq     = "Daily",
    source   = "Gold Traders Association (goldtraders.or.th)"
  )

  if (push_series(token, row$doc_id, row$label, df, is_incremental, meta = meta)) {
    ok_count <- ok_count + 1
    new_status[[row$doc_id]] <- max(df$date, na.rm = TRUE)
  }
}

message("── Updating meta/fetch_status...")
push_fetch_status(token, new_status)

message(sprintf("\n✓ Done — %d/%d Thai gold series updated", ok_count, nrow(SERIES_DEF)))
