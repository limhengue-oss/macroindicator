# ══════════════════════════════════════════════════════════════════
#  fetch_eppo.R
#  Scrape old.eppo.go.th → parse xlsx → append ลง Firestore
#  รัน: Rscript fetch_eppo.R
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(httr2)
  library(rvest)
  library(readxl)
  library(jsonlite)
  library(jose)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(purrr)
})

# ── Config ────────────────────────────────────────────────────────
PROJECT_ID   <- "macroindicator-6b265"
COLLECTION   <- "series"
BASE_URL     <- "https://old.eppo.go.th"
LIST_URL     <- paste0(BASE_URL, "/index.php/th/petroleum/price/structure-oil-price")
DELAY        <- 1.0

# cell positions (format ล่าสุด)
DATE_ROW     <- 3;  DATE_COL  <- 2   # B3
HEADER_ROW   <- 5
DATA_START   <- 6;  DATA_END  <- 15
EXRATE_ROW   <- 17; EXRATE_COL <- 3  # C17

FIELDS_COL <- list(
  EX_REFIN         = 2,
  EXCISE_TAX       = 3,
  M_TAX            = 4,
  OIL_FUND         = 5,
  CONSV_FUND       = 6,
  WHOLESALE        = 7,
  VAT_WS           = 8,
  # col9 = WS&VAT — ข้าม
  MARKETING_MARGIN = 10,
  VAT_MM           = 11,
  RETAIL           = 12
)

# fields ที่ push ลง Firestore — ตรงกับ backfill CSV schema
ALL_FIELDS <- c("EX_REFIN","EXCISE_TAX","M_TAX","OIL_FUND","CONSV_FUND",
                "VAT_WS","MARKETING_MARGIN","VAT_MM","RETAIL","WHOLESALE","EX_RATE")

# ── Credentials ───────────────────────────────────────────────────
sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

# ── Helpers ───────────────────────────────────────────────────────
# map product name → BASE_PRODUCT (รองรับชื่อที่เปลี่ยนตามเวลา)
PRODUCT_TO_BASE <- list(
  # DIESEL — B7 เป็น priority, B20 skip (ไม่อยู่ใน backfill schema)
  "H-DIESEL"            = "DIESEL",
  "H-DIESEL "           = "DIESEL",
  "H-DIESEL B7"         = "DIESEL",
  "H-DIESEL  B7"        = "DIESEL",
  # ULG 95
  "ULG95"               = "ULG 95",
  "ULG 95"              = "ULG 95",
  "ULG95R : UNL"        = "ULG 95",
  # GASOHOL 95
  "GASOHOL95 E10"       = "GASOHOL 95",
  "GASOHOL 95"          = "GASOHOL 95",
  "GASOHOL95"           = "GASOHOL 95",
  # GASOHOL 91
  "GASOHOL91"           = "GASOHOL 91",
  "GASOHOL 91"          = "GASOHOL 91",
  # E20, E85
  "GASOHOL95 E20"       = "GASOHOL95 E20",
  "GASOHOL95 E85"       = "GASOHOL95 E85",
  # LPG
  "LPG (BAHT/KILOGRAM)" = "LPG",
  "LPG"                 = "LPG",
  # FO
  "FO 1500 (2) 2%S"     = "FO 1500",
  "FO 1500 2%S"         = "FO 1500",
  "FO 600 (1) 2%S"      = "FO 600",
  "FO 600 2%S"          = "FO 600"
)

# products ที่ skip (ไม่อยู่ใน backfill schema)
SKIP_PRODUCTS <- c("H-DIESEL B20", "H-DIESEL 20")

make_doc_id <- function(base_product, field) {
  p <- base_product |>
    str_replace_all("[^A-Za-z0-9]+", "_") |>
    str_replace_all("_+", "_") |>
    str_remove("^_|_$") |>
    toupper()
  paste0("EPPO_", p, "_", field)
}

resolve_base <- function(product_name) {
  clean <- str_squish(product_name)   # trim + collapse internal spaces
  if (clean %in% SKIP_PRODUCTS) return(NULL)
  base <- PRODUCT_TO_BASE[[clean]]
  if (is.null(base)) {
    message(sprintf("  ⚠ Unknown product: '%s' — skipping", clean))
    return(NULL)
  }
  base
}

# แปลงชื่อเดือนไทย → เลข
thai_month <- c(
  "มกราคม"=1,"กุมภาพันธ์"=2,"มีนาคม"=3,"เมษายน"=4,
  "พฤษภาคม"=5,"มิถุนายน"=6,"กรกฎาคม"=7,"สิงหาคม"=8,
  "กันยายน"=9,"ตุลาคม"=10,"พฤศจิกายน"=11,"ธันวาคม"=12
)

parse_thai_date <- function(txt) {
  # "วันพฤหัสบดี, 25 มิถุนายน 2569"
  txt <- str_trim(txt)
  m   <- str_match(txt, "(\\d{1,2})\\s+([ก-์]+)\\s+(\\d{4})")
  if (is.na(m[1])) return(NA_character_)
  day  <- as.integer(m[2])
  mon  <- thai_month[m[3]]
  year <- as.integer(m[4]) - 543   # พ.ศ. → ค.ศ.
  if (is.na(mon) || is.na(year)) return(NA_character_)
  as.character(as.Date(sprintf("%04d-%02d-%02d", year, mon, day)))
}

eppo_get <- function(url) {
  request(url) |>
    req_headers(
      "User-Agent"      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
      "Accept-Language" = "th-TH,th;q=0.9,en;q=0.8"
    ) |>
    req_timeout(30) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
}

# ── Firestore auth ────────────────────────────────────────────────
get_token <- function(sa) {
  now <- as.numeric(Sys.time())
  claim <- jwt_claim(
    iss   = sa$client_email,
    scope = "https://www.googleapis.com/auth/datastore",
    aud   = "https://oauth2.googleapis.com/token",
    iat   = now, exp = now + 3600
  )
  jwt <- jwt_encode_sig(claim, key = gsub("\\\\n", "\n", sa$private_key))
  resp <- request("https://oauth2.googleapis.com/token") |>
    req_body_form(grant_type = "urn:ietf:params:oauth:grant-type:jwt-bearer",
                  assertion  = jwt) |>
    req_perform()
  resp_body_json(resp)$access_token
}

# dedup ตาม date (จุดที่มาทีหลังใน list ชนะถ้าวันที่ซ้ำ) แล้ว sort ตามวันที่
dedup_sort_points <- function(pts) {
  if (length(pts) == 0) return(pts)
  dates <- map_chr(pts, \(p) p$mapValue$fields$d$stringValue)
  keep  <- !duplicated(dates, fromLast = TRUE)
  pts   <- pts[keep]
  dates <- dates[keep]
  pts[order(dates)]
}

# ── Firestore: append points ──────────────────────────────────────
append_series <- function(token, doc_id, name, new_df) {
  # new_df: tibble(date, value) — วันที่ยังไม่มีใน Firestore
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )
  # GET existing
  existing_pts <- tryCatch({
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
  
  # new points
  new_pts <- pmap(new_df, function(date, value) {
    list(mapValue = list(fields = list(
      d = list(stringValue = as.character(date)),
      v = list(doubleValue  = value)
    )))
  })
  
  all_pts <- dedup_sort_points(c(existing_pts, new_pts))

  body <- list(fields = list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = all_pts))
  ))
  
  resp <- request(url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  
  status <- resp_status(resp)
  if (status >= 300) {
    warning(sprintf("  ✗ %s HTTP %d", doc_id, status))
    return(FALSE)
  }
  message(sprintf("  ✓ %s (+%d pts)", doc_id, nrow(new_df)))
  TRUE
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

# 1. อ่าน meta/eppo_status
message("── Reading meta/eppo_status...")
meta_url <- sprintf(
  "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/eppo_status",
  PROJECT_ID
)
meta_resp <- request(meta_url) |>
  req_auth_bearer_token(token) |>
  req_error(is_error = \(r) FALSE) |>
  req_perform()

if (resp_status(meta_resp) != 200) {
  stop("meta/eppo_status ไม่พบ — รัน init_eppo_meta.R ก่อน")
}

meta        <- resp_body_json(meta_resp)
last_date   <- as.Date(meta$fields$last_date$stringValue)
meta_fields <- map_chr(meta$fields$fields$arrayValue$values,
                       \(v) v$stringValue)
meta_products <- map_chr(meta$fields$products$arrayValue$values,
                         \(v) v$stringValue)

message(sprintf("  last_date = %s", last_date))
message(sprintf("  fields    = %s", paste(meta_fields, collapse = ", ")))
message(sprintf("  products  = %s", paste(meta_products, collapse = ", ")))

# 2. Scrape สูงสุด 3 หน้า
message("── Scraping EPPO list (max 3 pages)...")
pending  <- list()
MAX_PAGE <- 3

for (page in 0:(MAX_PAGE - 1)) {
  url  <- if (page == 0) LIST_URL else paste0(LIST_URL, "?start=", page * 9)
  resp <- eppo_get(url)

  if (resp_status(resp) != 200) {
    message("  HTTP ", resp_status(resp), " at page ", page, " — stop")
    break
  }

  html     <- resp_body_string(resp) |> read_html()
  dl_nodes <- html |> html_elements("a[href*='download']")

  if (length(dl_nodes) == 0) {
    message("  page ", page, ": no items — stop")
    break
  }

  pairs <- map(dl_nodes, function(node) {
    href     <- html_attr(node, "href")
    date_txt <- node |>
      xml2::xml_parent() |>
      xml2::xml_parent() |>
      html_element("div[style*='float:left']") |>
      html_text(trim = TRUE)
    list(date_txt = date_txt %||% "", href = href)
  })

  done <- FALSE
  for (pair in pairs) {
    wd_str <- parse_thai_date(pair$date_txt)
    if (is.na(wd_str)) next
    wd <- as.Date(wd_str)
    if (is.na(wd)) next
    if (wd <= last_date) { done <- TRUE; break }
    pending[[length(pending) + 1]] <- list(web_date = wd, link = pair$href)
  }

  message(sprintf("  page %d: %d links, %d pending so far",
                  page, length(dl_nodes), length(pending)))
  if (done) break
  Sys.sleep(DELAY)
}

message(sprintf("  %d new file(s) to download (last_date = %s)", length(pending), last_date))
if (length(pending) == 0) {
  message("✓ Already up to date")
  quit(save = "no", status = 0)
}

pending <- rev(pending)  # เรียงเก่า → ใหม่

# 3. Download + validate + parse
all_rows    <- list()
latest_date <- NULL

for (item in pending) {
  web_date <- item$web_date
  dl_url   <- paste0(BASE_URL, item$link)
  message(sprintf("\n── [%s] %s", web_date, item$link))

  resp <- eppo_get(dl_url)
  if (resp_status(resp) != 200) {
    message("  ✗ HTTP ", resp_status(resp), " — skip")
    next
  }

  tmp <- tempfile(fileext = ".xlsx")
  writeBin(resp_body_raw(resp), tmp)

  ws <- tryCatch(
    read_xlsx(tmp, col_names = FALSE, col_types = "text", sheet = "Oil Price Structure"),
    error = function(e) tryCatch(
      read_xlsx(tmp, col_names = FALSE, col_types = "text", sheet = 1),
      error = function(e2) { message("  ✗ read_xlsx: ", e2$message); NULL }
    )
  )
  unlink(tmp)
  if (is.null(ws)) next

  # validate: C col DATA_START ต้องเป็นตัวเลข
  val_check <- suppressWarnings(as.numeric(as.character(ws[DATA_START, 3])))
  if (is.na(val_check)) {
    message(sprintf("  ✗ [%s] col3 row%d not numeric — skip", web_date, DATA_START))
    next
  }

  # validate: products ที่ parse ได้ตรงกับ meta_products
  parsed_products <- c()
  for (r in DATA_START:min(DATA_END, nrow(ws))) {
    p <- str_squish(as.character(ws[r, 1]))
    b <- resolve_base(p)
    if (!is.null(b)) parsed_products <- c(parsed_products, b)
  }
  parsed_products <- unique(parsed_products)
  missing_products <- setdiff(meta_products, parsed_products)
  if (length(missing_products) > 0) {
    message(sprintf("  ✗ [%s] missing products: %s — skip",
                    web_date, paste(missing_products, collapse = ", ")))
    next
  }

  # validate: ไฟล์มี column ครบตาม FIELDS_COL (เช็คว่า col index ไม่เกิน ncol)
  max_col_needed <- max(unlist(FIELDS_COL))
  if (ncol(ws) < max_col_needed) {
    message(sprintf("  ✗ [%s] only %d cols, need %d — stop (format may have changed)",
                    web_date, ncol(ws), max_col_needed))
    stop("Column count mismatch — ไม่ push เพื่อป้องกัน data corruption")
  }

  # parse rows
  exrate <- suppressWarnings(as.numeric(as.character(ws[EXRATE_ROW, EXRATE_COL])))

  for (r in DATA_START:min(DATA_END, nrow(ws))) {
    product <- str_squish(as.character(ws[r, 1]))
    if (is.na(product) || product == "" || product == "NA") next
    base <- resolve_base(product)
    if (is.null(base)) next

    row_data <- list(DATE = as.character(web_date), PRODUCT_CLEAN = product,
                     BASE_PRODUCT = base, EX_RATE = exrate)
    for (field in names(FIELDS_COL)) {
      col_idx <- FIELDS_COL[[field]]
      v <- if (col_idx <= ncol(ws)) suppressWarnings(as.numeric(as.character(ws[r, col_idx]))) else NA_real_
      row_data[[field]] <- v
    }
    all_rows[[length(all_rows) + 1]] <- row_data
  }

  latest_date <- web_date
  message(sprintf("  ✓ parsed %s", web_date))
  Sys.sleep(DELAY)
}

if (length(all_rows) == 0) {
  message("No valid rows parsed")
  quit(save = "no", status = 0)
}

df_new <- bind_rows(all_rows)
message(sprintf("\n── Parsed %d rows across %d dates",
                nrow(df_new), n_distinct(df_new$DATE)))

# 4. Push ลง Firestore
message("── Pushing to Firestore...")
ok <- 0

for (base in unique(df_new$BASE_PRODUCT)) {
  df_prod <- df_new |>
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
    if (append_series(token, doc_id, label, df_series)) ok <- ok + 1
    Sys.sleep(0.1)
  }
}

message(sprintf("── Pushed %d series", ok))

# 5. Update meta/eppo_status.last_date
if (!is.null(latest_date)) {
  message("── Updating meta/eppo_status...")
  body <- list(fields = list(
    last_date = list(stringValue = as.character(latest_date)),
    fields    = list(arrayValue = list(
      values = map(as.list(meta_fields), \(f) list(stringValue = f))
    )),
    products  = list(arrayValue = list(
      values = map(as.list(meta_products), \(p) list(stringValue = p))
    )),
    updated   = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"))
  ))
  r <- request(meta_url) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(r) < 300) {
    message(sprintf("  ✓ last_date updated to %s", latest_date))
  } else {
    message(sprintf("  ✗ HTTP %d updating meta", resp_status(r)))
  }
}

message(sprintf("\n✓ Done — pushed %d series", ok))
