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
REF_DOC      <- "EPPO_H_DIESEL_RETAIL"   # ใช้เช็ค last_date
FLAG_FILE    <- "eppo_format_flag.txt"
DELAY        <- 1.0

# cell positions (format ล่าสุด)
DATE_ROW     <- 4;  DATE_COL  <- 2   # B4
HEADER_ROW   <- 6
DATA_START   <- 7;  DATA_END  <- 15
EXRATE_ROW   <- 18; EXRATE_COL <- 4  # D18

FIELDS_COL <- list(
  EX_REFIN         = 3,
  EXCISE_TAX       = 4,
  M_TAX            = 5,
  OIL_FUND         = 6,
  CONSV_FUND       = 7,
  WHOLESALE        = 8,
  VAT_WS           = 9,
  # col10 = WS&VAT (ข้ามไป ไม่อยู่ใน backfill schema)
  MARKETING_MARGIN = 11,
  VAT_MM           = 12,
  RETAIL           = 13
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
SKIP_PRODUCTS <- c("H-DIESEL  B20", "H-DIESEL B20", "H-DIESEL 20")

make_doc_id <- function(base_product, field) {
  p <- base_product |>
    str_replace_all("[^A-Za-z0-9]+", "_") |>
    str_replace_all("_+", "_") |>
    str_remove("^_|_$") |>
    toupper()
  paste0("EPPO_", p, "_", field)
}

resolve_base <- function(product_name) {
  if (str_trim(product_name) %in% SKIP_PRODUCTS) return(NULL)
  base <- PRODUCT_TO_BASE[[product_name]]
  if (is.null(base)) {
    message(sprintf("  ⚠ Unknown product: '%s' — skipping", product_name))
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

flag_format_change <- function(msg) {
  writeLines(c(format(Sys.time()), msg), FLAG_FILE)
  message("⚠ FORMAT CHANGE: ", msg)
  stop(paste("FORMAT CHANGE:", msg))
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

# ── Firestore: get last date ──────────────────────────────────────
get_last_date <- function(token, doc_id) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )
  tryCatch({
    r <- request(url) |>
      req_auth_bearer_token(token) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(r) != 200) return(as.Date("1990-01-01"))
    d   <- resp_body_json(r)
    arr <- d$fields$data$arrayValue$values
    if (is.null(arr)) return(as.Date("1990-01-01"))
    dates <- map_chr(arr, \(v) v$mapValue$fields$d$stringValue)
    max(as.Date(dates), na.rm = TRUE)
  }, error = function(e) as.Date("1990-01-01"))
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
  
  all_pts <- c(existing_pts, new_pts)
  
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
token    <- get_token(sa)
message("  ✓ token OK")

# 1. เช็ค last_date จาก Firestore
message("── Checking last date from Firestore (", REF_DOC, ")...")
last_date <- get_last_date(token, REF_DOC)
message("  last_date = ", last_date)

# 2. Scrape สูงสุด 3 หน้า — เว็บเรียงล่าสุดมาก่อน ดึงแค่ที่ยังไม่มี
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

  message(sprintf("  page %d: %d links, %d pending so far", page, length(dl_nodes), length(pending)))
  if (done) break
  Sys.sleep(DELAY)
}

message(sprintf("  %d new file(s) to download (last_date = %s)", length(pending), last_date))
if (length(pending) == 0) {
  message("✓ Already up to date")
  quit(save = "no", status = 0)
}

# เรียงจากเก่าไปใหม่ (push chronologically)
pending <- rev(pending)

# 3. Download + validate + parse + push
all_rows <- list()   # เก็บทุก row ของวันที่ดาวน์โหลดมา

for (item in pending) {
  web_date <- item$web_date
  link     <- item$link
  dl_url   <- paste0(BASE_URL, link)
  
  message(sprintf("\n── [%s] %s", web_date, link))
  
  # download xlsx
  tmp  <- tempfile(fileext = ".xlsx")
  resp <- eppo_get(dl_url)
  if (resp_status(resp) != 200) {
    message("  ✗ download failed HTTP ", resp_status(resp))
    next
  }
  writeBin(resp_body_raw(resp), tmp)
  
  # อ่าน xlsx — text สำหรับ data, date แยกสำหรับ B4
  ws <- tryCatch(
    read_xlsx(tmp, col_names = FALSE, col_types = "text", sheet = "Oil Price Structure"),
    error = function(e) { message("  ✗ read_xlsx error: ", e$message); NULL }
  )
  if (is.null(ws)) { unlink(tmp); next }

  # อ่าน B4 แยกด้วย col_types="date" เพราะ "text" แปลง date เป็น NA
  ws_date <- tryCatch(
    read_xlsx(tmp, col_names = FALSE, col_types = "date",
              sheet = "Oil Price Structure", range = "B4:B4"),
    error = function(e) NULL
  )
  unlink(tmp)

  file_date <- tryCatch({
    if (!is.null(ws_date) && !is.na(ws_date[[1,1]])) {
      as.Date(ws_date[[1,1]])
    } else {
      # fallback: ลอง parse จาก text cell
      date_raw <- as.character(ws[DATE_ROW, DATE_COL])
      n <- suppressWarnings(as.numeric(date_raw))
      if (!is.na(n)) as.Date(n, origin = "1899-12-30")
      else as.Date(substr(date_raw, 1, 10))
    }
  }, error = function(e) as.Date(NA))

  if (is.na(file_date)) {
    flag_format_change(sprintf("[%s] Cannot parse date from B4", web_date))
    next
  }
  
  # เช็คว่า file_date ตรงกับ web_date
  if (file_date != web_date) {
    message(sprintf("  ⚠ date mismatch: web=%s file=%s — skip", web_date, file_date))
    next
  }
  
  # validate: header row 6 มี EX-REFIN และ RETAIL
  header_vals <- as.character(ws[HEADER_ROW, ])
  if (!any(str_detect(na.omit(header_vals), "(?i)EX.REFIN"))) {
    flag_format_change(sprintf("[%s] EX-REFIN not found in header row 6", web_date))
    next
  }
  if (!any(str_detect(na.omit(header_vals), "(?i)RETAIL"))) {
    flag_format_change(sprintf("[%s] RETAIL not found in header row 6", web_date))
    next
  }
  
  # validate: C7 เป็นตัวเลข
  val_check <- suppressWarnings(as.numeric(as.character(ws[DATA_START, 3])))
  if (is.na(val_check)) {
    flag_format_change(sprintf("[%s] C7 not numeric — table may have shifted", web_date))
    next
  }
  
  # EX_RATE D18
  exrate <- suppressWarnings(as.numeric(as.character(ws[EXRATE_ROW, EXRATE_COL])))
  
  # parse rows
  for (r in DATA_START:min(DATA_END, nrow(ws))) {
    product <- str_trim(as.character(ws[r, 2]))
    if (is.na(product) || product == "" || product == "NA") next
    
    base <- resolve_base(product)
    row_data <- list(DATE = as.character(web_date), PRODUCT = product,
                     BASE_PRODUCT = base, EX_RATE = exrate)
    
    for (field in names(FIELDS_COL)) {
      col_idx <- FIELDS_COL[[field]]
      v <- if (col_idx <= ncol(ws)) suppressWarnings(as.numeric(as.character(ws[r, col_idx]))) else NA_real_
      row_data[[field]] <- v
    }
    
    all_rows[[length(all_rows) + 1]] <- row_data
  }
  
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

# group by BASE_PRODUCT ก่อน push
base_products <- unique(df_new$BASE_PRODUCT)
for (base in base_products) {
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

message(sprintf("\n✓ Done — pushed %d series", ok))
