# ══════════════════════════════════════════════════════════════════
#  fetch_bot.R
#  ดึงข้อมูลเศรษฐกิจมหภาคไทยจาก Bank of Thailand Open Data API
#  (gateway.api.bot.or.th/observations/) → push ขึ้น Firestore
#
#  Environment variables ที่ต้องตั้ง:
#    BOT_API_KEY  — BOT API key (Authorization header, ไม่มี "Bearer" prefix)
#    GCP_SA_KEY   — service account JSON (ทั้งก้อน เป็น string)
#
#  รัน local:  Rscript fetch_bot.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets
#
#  หมายเหตุ API:
#   - endpoint คืนค่าได้สูงสุด 120 observations ต่อ 1 request ไม่ว่าช่วงวันที่
#     จะกว้างแค่ไหน (เกินจะไม่ error แค่ตัดทิ้ง) — ต้อง paginate เป็นช่วงๆ
#   - ถ้า start_period ที่ส่งไปเก่ากว่าจุดเริ่มต้นจริงของ series
#     (observation_start) API จะคืนค่าว่างทั้งก้อน (ไม่ error) — ต้องเริ่ม
#     query จาก observation_start จริงเท่านั้น (เก็บไว้ใน CATALOG ด้านล่าง)
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
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
DATE_TO    <- Sys.Date()

# ── 0. อ่าน credentials จาก env ────────────────────────────────────
bot_key <- Sys.getenv("BOT_API_KEY")
sa_json <- Sys.getenv("GCP_SA_KEY")

if (bot_key == "") stop("BOT_API_KEY not set")
if (sa_json == "") stop("GCP_SA_KEY not set")

sa <- fromJSON(sa_json)

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

# ══════════════════════════════════════════════════════════════════
#  PART 1 — Firestore auth (เหมือน fetch_and_push.R)
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
#  PART 2 — BOT API client
# ══════════════════════════════════════════════════════════════════

# period_start ที่ API คืนมา ขึ้นกับ frequency:
#   Daily     "YYYY-MM-DD"
#   Monthly   "YYYY-MM"
#   Quarterly "YYYY-Qn"
parse_bot_period <- function(period_start, freq) {
  if (freq == "D") return(as.Date(period_start))
  if (freq == "M") return(as.Date(paste0(period_start, "-01")))
  if (freq == "Q") {
    year <- as.integer(str_sub(period_start, 1, 4))
    q    <- as.integer(str_sub(period_start, -1))
    month <- (q - 1) * 3 + 1
    return(as.Date(sprintf("%d-%02d-01", year, month)))
  }
  NA
}

# แบ่งช่วง [from, to] เป็น window ละ ~100 period กัน cap 120 rows/request
make_windows <- function(from, to, freq) {
  if (from > to) return(tibble(start = as.Date(character()), end = as.Date(character())))
  step <- switch(freq, D = "100 day", M = "100 month", Q = "300 month")  # 300mo = 100 quarters
  starts <- seq(from, to, by = step)
  if (length(starts) == 0) starts <- from
  ends <- c(starts[-1] - 1, to)
  ends <- pmin(ends, to)
  tibble(start = starts, end = ends) |> filter(start <= to)
}

# ดึง 1 window จาก observations/ — คืน list(df=tibble(date,value), meta=list(...))
fetch_bot_window <- function(series_code, start_period, end_period) {
  tryCatch({
    resp <- request("https://gateway.api.bot.or.th/observations/") |>
      req_url_query(
        series_code = series_code,
        start_period = as.character(start_period),
        end_period   = as.character(end_period)
      ) |>
      req_headers(Authorization = bot_key, Accept = "application/json") |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()

    if (resp_status(resp) >= 300) stop(sprintf("HTTP %d", resp_status(resp)))

    s <- resp_body_json(resp)$result$series[[1]]
    if (is.null(s$series_code)) return(list(df = tibble(date = as.Date(character()), value = numeric()), meta = NULL))

    freq_code <- switch(s$frequency %||% "", Daily = "D", Monthly = "M", Quarterly = "Q", NA_character_)
    obs <- s$observations
    df <- if (length(obs) == 0) {
      tibble(date = as.Date(character()), value = numeric())
    } else {
      tibble(
        date  = map_vec(obs, \(o) parse_bot_period(o$period_start, freq_code), .ptype = as.Date(character())),
        value = map_dbl(obs, \(o) as.numeric(o$value))
      ) |> filter(!is.na(date), is.finite(value))
    }

    unit_eng <- s$unit_eng %||% ""
    currency <- if (str_detect(unit_eng, regex("Dollar", ignore_case = TRUE))) "USD"
                else if (str_detect(unit_eng, regex("Baht", ignore_case = TRUE))) "THB"
                else ""

    meta <- list(
      fullName = s$series_name_eng %||% series_code,
      currency = currency,
      unit     = unit_eng,
      freq     = s$frequency %||% "",
      source   = paste0("Bank of Thailand (", series_code, ")")
    )

    list(df = df, meta = meta)
  }, error = function(e) {
    warning(sprintf("  bot SKIP %s [%s..%s]: %s", series_code, start_period, end_period, e$message))
    list(df = tibble(date = as.Date(character()), value = numeric()), meta = NULL)
  })
}

# ดึงข้อมูลทั้งช่วง [from, to] โดย paginate ตาม window — คืน list(df, meta)
fetch_bot_series <- function(series_code, freq, from, to = DATE_TO) {
  windows <- make_windows(from, to, freq)
  if (nrow(windows) == 0) return(list(df = tibble(date = as.Date(character()), value = numeric()), meta = NULL))

  dfs <- list()
  meta <- NULL
  for (i in seq_len(nrow(windows))) {
    w <- fetch_bot_window(series_code, windows$start[i], windows$end[i])
    dfs[[i]] <- w$df
    if (!is.null(w$meta)) meta <- w$meta
    Sys.sleep(0.15)
  }
  df <- bind_rows(dfs) |> distinct(date, .keep_all = TRUE) |> arrange(date)
  list(df = df, meta = meta)
}

# ══════════════════════════════════════════════════════════════════
#  PART 3 — Catalog (doc_id, series_code, freq, observation_start จริง)
#  freq: D=Daily, M=Monthly, Q=Quarterly
#  observation_start ต้องตรงกับที่ BOT ประกาศไว้จริง (เช็คแล้วจาก
#  categorylist/series_list — ถ้าใส่วันที่เก่ากว่านี้ API จะคืนค่าว่าง)
# ══════════════════════════════════════════════════════════════════
CATALOG <- tribble(
  ~doc_id,                ~series_code,           ~freq, ~obs_start,
  # กิจกรรมเศรษฐกิจ
  "BOT_LEI",              "EILEIM00007",          "M",   "2000-01-01",
  "BOT_BSI",              "EIBSIM00057",          "M",   "1999-01-01",
  "BOT_PCI",              "EIPCIM00046",          "M",   "2010-01-01",
  "BOT_PII",              "EIPIIM00057",          "M",   "2018-01-01",
  "BOT_SET_BOT",          "EILEIM00013",          "M",   "2000-01-01",
  # แรงงาน
  "BOT_UNEMP",            "RLLFSWKM00079",        "M",   "2011-01-01",
  # ต่างประเทศ
  "BOT_EXPORT",           "XTBOP0OVL0M15593",     "M",   "2005-01-01",
  "BOT_IMPORT",           "XTBOP0OVL0M15594",     "M",   "2005-01-01",
  "BOT_TRADEBAL",         "XTBOP0OVL0M15595",     "M",   "2005-01-01",
  "BOT_CURACC",           "XTBOP0OVL0M15597",     "M",   "2005-01-01",
  "BOT_RESERVES",         "XTRSV00000M00698",     "M",   "1993-01-01",
  "BOT_FWDPOS",           "XTRSV00000M00699",     "M",   "1993-01-01",
  "BOT_TOURIST",          "EITOURISTM00267",      "M",   "2015-01-01",
  "BOT_USDTHB",           "FMEXRUSDAVGMDD015588", "D",   "2002-01-02",
  # ดอกเบี้ย/การเงิน
  "BOT_M2",               "EILEIM00014",          "M",   "2000-01-01",
  "BOT_YIELD_1M",         "FMRTINTM00284",        "M",   "2024-07-01",
  "BOT_YIELD_3M",         "FMRTINTM00285",        "M",   "2024-07-01",
  "BOT_YIELD_6M",         "FMRTINTM00286",        "M",   "2024-07-01",
  "BOT_YIELD_1Y",         "FMRTINTM00287",        "M",   "2024-07-01",
  "BOT_YIELD_2Y",         "FMRTINTM00288",        "M",   "2024-07-01",
  "BOT_YIELD_5Y",         "FMRTINTM00291",        "M",   "2024-07-01",
  "BOT_YIELD_10Y",        "FMRTINTM00296",        "M",   "2024-07-01",
  "BOT_YIELD_20Y",        "FMRTINTM00306",        "M",   "2024-07-01",
  # การคลัง
  "BOT_GOVDEBT",          "PF00000000M00068",     "M",   "2007-01-01",
  "BOT_CASHBAL",          "PFCG000000M000465",    "M",   "2009-01-01",
  # เสถียรภาพระบบการเงิน
  "BOT_NPL",              "ECFSDICBCOREQ000036",  "Q",   "2017-01-01",
  "BOT_HHDEBT_GDP",       "ECFSHH00ADDTQ000053",  "Q",   "2017-01-01",
  "BOT_EXTDEBT_GDP",      "XTEDBT0000Q00796",     "Q",   "2005-01-01",
  "BOT_RESERVES_STDEBT",  "XTEDBT0000Q00797",     "Q",   "2005-01-01"
)

# ══════════════════════════════════════════════════════════════════
#  PART 4 — fetch_status (incremental) — ใช้ collection meta/fetch_status
#  ร่วมกับ fetch_and_push.R (คนละ doc_id namespace เลยไม่ชนกัน)
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
#  PART 5 — Main
# ══════════════════════════════════════════════════════════════════
message("── Authenticating with Firestore...")
token <- get_access_token(sa)
message("  ✓ token acquired")

message("── Reading meta/fetch_status...")
fetch_status <- get_fetch_status(token)
message(sprintf("  %d series have prior last_date", length(fetch_status)))

message("── Fetching + pushing ", nrow(CATALOG), " BOT series...")

ok_count <- 0
new_status <- fetch_status

for (i in seq_len(nrow(CATALOG))) {
  row <- CATALOG[i, ]
  is_incremental <- !is.null(fetch_status[[row$doc_id]])
  from <- if (is_incremental) fetch_status[[row$doc_id]] + 1 else as.Date(row$obs_start)

  message(sprintf("  [%d/%d] %s (%s) from %s...", i, nrow(CATALOG), row$doc_id, row$series_code, from))
  result <- fetch_bot_series(row$series_code, row$freq, from, DATE_TO)
  df   <- result$df
  meta <- result$meta

  if (nrow(df) == 0) {
    message(sprintf("  ⊘ %s: no new data since %s", row$doc_id, from))
    next
  }

  name <- if (!is.null(meta)) sprintf("BOT %s", meta$fullName) else row$doc_id

  if (push_series(token, row$doc_id, name, df, is_incremental, meta = meta)) {
    ok_count <- ok_count + 1
    new_status[[row$doc_id]] <- max(df$date, na.rm = TRUE)
  }
}

message("── Updating meta/fetch_status...")
push_fetch_status(token, new_status)

message(sprintf("\n✓ Done — %d/%d BOT series updated", ok_count, nrow(CATALOG)))
