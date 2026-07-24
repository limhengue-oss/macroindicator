# ══════════════════════════════════════════════════════════════════
#  fetch_thaibma.R
#  ดึง Government Bond Yield Curve รายวันจาก ThaiBMA (internal JSON API
#  ที่หน้า thaibma.or.th/EN/Market/YieldCurve/Government.aspx เรียกใช้)
#  → push ขึ้น Firestore
#
#  Endpoint: GET https://www.thaibma.or.th/yieldcurve/gov/{YYYY-MM-DD}
#    - ไม่ต้อง API key, เป็น public JSON endpoint
#    - คืนค่าทีละ 1 วันเท่านั้น (ไม่มี date-range param) — ต้อง loop เอง
#    - ถ้าวันที่ขอเป็นวันหยุด/เสาร์-อาทิตย์ จะ auto-roll back ไปวันทำการ
#      ล่าสุดให้เอง (field "Asof" ในผลลัพธ์บอกวันที่จริง) — ต้อง dedup
#      ตาม Asof เอง เพราะเราไม่รู้ปฏิทินวันหยุดไทยล่วงหน้า
#    - field X = tenor (ปี), Y = yield (%)
#
#  Environment variables ที่ต้องตั้ง:
#    GCP_SA_KEY — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_thaibma.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
#
#  Backfill: ถ้า series ยังไม่เคยมีข้อมูล (ครั้งแรก) จะดึงย้อนหลังแค่ ~35
#  วันปฏิทิน (พอสำหรับ trend เดือนล่าสุด) จากนั้นรอบถัดๆ ไปจะดึงต่อจาก
#  วันล่าสุดที่มีอยู่ทุกวัน (fetch_status) สะสมประวัติไปเรื่อยๆ
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

PROJECT_ID    <- "macroindicator-6b265"
COLLECTION    <- "series"
DATE_TO       <- Sys.Date()
BACKFILL_DAYS <- 35   # ครั้งแรกที่ยังไม่มีข้อมูล ย้อนหลังกี่วันปฏิทิน

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
#  PART 2 — ThaiBMA client
# ══════════════════════════════════════════════════════════════════

# tenor ที่ต้องการ (label → X ปี ที่ ThaiBMA ใช้จริง ต้อง match แบบ tolerance
# เพราะ X ของ 1M/3M/6M ไม่ใช่เลขกลมๆ เช่น 1M = 28/365 = 0.0767123...)
TARGET_TENORS <- tribble(
  ~doc_id,                ~label, ~x_years,
  "THAIBMA_YIELD_1M",     "1M",   0.076712328767123,
  "THAIBMA_YIELD_3M",     "3M",   0.249315068493151,
  "THAIBMA_YIELD_6M",     "6M",   0.498630136986301,
  "THAIBMA_YIELD_1Y",     "1Y",   1,
  "THAIBMA_YIELD_2Y",     "2Y",   2,
  "THAIBMA_YIELD_5Y",     "5Y",   5,
  "THAIBMA_YIELD_10Y",    "10Y",  10,
  "THAIBMA_YIELD_20Y",    "20Y",  20
)

# ดึง yield curve ของ 1 วัน (คืน NULL ถ้าล้มเหลว)
fetch_thaibma_day <- function(date) {
  tryCatch({
    url <- sprintf("https://www.thaibma.or.th/yieldcurve/gov/%s", format(date, "%Y-%m-%d"))
    resp <- request(url) |>
      req_headers(
        `User-Agent` = "Mozilla/5.0 (compatible; macroindicator-bot/1.0)",
        Accept       = "application/json"
      ) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))
    d <- resp_body_json(resp)
    curve <- d$Curve
    if (length(curve) == 0) return(NULL)
    asof <- as.Date(substr(curve[[1]]$Asof, 1, 10))
    tibble(
      asof = asof,
      x    = map_dbl(curve, \(p) p$X),
      y    = map_dbl(curve, \(p) p$Y)
    )
  }, error = function(e) {
    warning(sprintf("  thaibma SKIP %s: %s", date, e$message))
    NULL
  })
}

# ดึงทุกวันทำการ (จ-ศ) ใน [from, to] แล้ว dedup ตาม Asof จริงที่ได้กลับมา
# (กันกรณีวันหยุดไทยที่ไม่รู้ล่วงหน้า — API roll back ให้เองแต่ค่าจะซ้ำกัน)
fetch_thaibma_range <- function(from, to) {
  weekdays_seq <- seq(from, to, by = "day")
  weekdays_seq <- weekdays_seq[!wday(weekdays_seq) %in% c(1, 7)]  # ตัดเสาร์-อาทิตย์
  if (length(weekdays_seq) == 0) return(tibble(asof = as.Date(character()), x = double(), y = double()))

  results <- list()
  for (i in seq_along(weekdays_seq)) {
    df <- fetch_thaibma_day(weekdays_seq[i])
    if (!is.null(df)) results[[length(results) + 1]] <- df
    Sys.sleep(0.3)
  }
  if (length(results) == 0) return(tibble(asof = as.Date(character()), x = double(), y = double()))
  bind_rows(results) |> distinct(asof, x, .keep_all = TRUE)
}

# แยก curve รวมออกเป็น series ต่อ tenor (nearest match ภายใน tolerance)
extract_tenor_series <- function(curve_df, x_years, tol = 0.01) {
  curve_df |>
    group_by(asof) |>
    filter(abs(x - x_years) == min(abs(x - x_years))) |>
    ungroup() |>
    filter(abs(x - x_years) <= tol) |>
    transmute(date = asof, value = y) |>
    distinct(date, .keep_all = TRUE) |>
    arrange(date)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — fetch_status (incremental, doc namespace แยกจาก series อื่น)
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
message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Reading meta/fetch_status...")
fetch_status <- get_fetch_status(token)

# หาว่า series ไหนใน batch นี้ยังไม่เคยมี fetch_status (ครั้งแรก) เพื่อกำหนด
# วันเริ่มต้นรวม (ใช้ค่า min เพื่อดึง curve ครอบคลุมทุก tenor ในรอบเดียวกัน)
any_new    <- any(!TARGET_TENORS$doc_id %in% names(fetch_status))
known_dates <- fetch_status[TARGET_TENORS$doc_id]
known_dates <- known_dates[!sapply(known_dates, is.null)]
from <- if (length(known_dates) > 0) min(unlist(known_dates)) |> as.Date() + 1 else DATE_TO - BACKFILL_DAYS
if (any_new) from <- min(from, DATE_TO - BACKFILL_DAYS)

message(sprintf("── Fetching ThaiBMA yield curve from %s to %s...", from, DATE_TO))
curve_df <- fetch_thaibma_range(from, DATE_TO)
message(sprintf("  %d curve-days fetched", n_distinct(curve_df$asof)))

ok_count <- 0
new_status <- fetch_status

for (i in seq_len(nrow(TARGET_TENORS))) {
  row <- TARGET_TENORS[i, ]
  is_incremental <- !is.null(fetch_status[[row$doc_id]])
  series_from <- if (is_incremental) fetch_status[[row$doc_id]] + 1 else as.Date(-Inf)

  df <- extract_tenor_series(curve_df, row$x_years) |> filter(date >= series_from)

  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no new data", row$doc_id))
    next
  }

  meta <- list(
    fullName = sprintf("ThaiBMA Government Bond Yield : %s", row$label),
    currency = "",
    unit     = "Percent",
    freq     = "Daily",
    source   = "ThaiBMA (thaibma.or.th — Government Bond Yield Curve)"
  )
  name <- meta$fullName

  if (push_series(token, row$doc_id, name, df, is_incremental, meta = meta)) {
    ok_count <- ok_count + 1
    new_status[[row$doc_id]] <- max(df$date, na.rm = TRUE)
  }
}

message("── Updating meta/fetch_status...")
push_fetch_status(token, new_status)

message(sprintf("\n✓ Done — %d/%d ThaiBMA yield series updated", ok_count, nrow(TARGET_TENORS)))
