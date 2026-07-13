# ══════════════════════════════════════════════════════════════════
#  fetch_eppo.R
#  1) OFFO scrape → append วันที่ใหม่
#  2) EPPO scrape → overwrite วันที่ซ้ำ + append วันที่ใหม่กว่า OFFO
#  รัน: Rscript fetch_eppo.R
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(httr2); library(rvest); library(readxl); library(pdftools)
  library(jsonlite); library(jose)
  library(dplyr); library(stringr); library(purrr)
})

# ── Config ────────────────────────────────────────────────────────
PROJECT_ID   <- "macroindicator-6b265"
COLLECTION   <- "series"
# EPPO ย้ายจาก old.eppo.go.th (หน้า list + download link) มาที่ www.eppo.go.th
# ตั้งแต่ ก.ค. 2569 — หน้าใหม่ (data-energy-statistic/energy-price-th/...) ต้องกรอก
# ฟอร์มค้นหาช่วงวันที่ถึงจะเห็นลิงก์ (scrape หน้าเว็บตรง ๆ ไม่ได้ง่าย ๆ) แต่หน้านั้น
# เรียกใช้ REST API ของ WordPress เองอยู่แล้วที่ EPPO_API_URL (คืน snapshot ล่าสุด
# เป็น JSON ตรง ๆ) ใช้ตัวนี้เป็นแหล่งหลักในการเช็ค/ดึงข้อมูลวันล่าสุด ส่วน URL ไฟล์เป็น
# pattern ตายตัวตามวันที่ (EPPO_FILE_BASE) ใช้ probe ตรงทีละวันเป็น fallback/double-check
EPPO_API_URL      <- "https://www.eppo.go.th/wp-json/oil-api/v1/oil-structure-prices"
EPPO_FILE_BASE    <- "https://www.eppo.go.th/wp-content/uploads"
OFFO_LIST         <- "https://www.offo.or.th/th/oil-price-structure-adjusted"
FUND_STATUS_LIST  <- "https://www.offo.or.th/th/estimate/fuelfund-status"
MAX_PAGES    <- 3
DELAY        <- 1.0
STALE_WEEKDAY_THRESHOLD <- 2  # แจ้งเตือนถ้าข้อมูลล่าสุด lag เกินกี่ "วันทำการ" (ไม่นับ ส-อา)

ALL_FIELDS <- c("EX_REFIN","EXCISE_TAX","M_TAX","OIL_FUND","CONSV_FUND",
                "VAT_WS","MARKETING_MARGIN","VAT_MM","RETAIL","WHOLESALE","EX_RATE")

# ── Credentials ───────────────────────────────────────────────────
sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

# ── Helpers ───────────────────────────────────────────────────────
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0) y else x

PRODUCT_TO_BASE <- list(
  "H-DIESEL"="DIESEL","H-DIESEL B7"="DIESEL","H-DIESEL  B7"="DIESEL",
  "ULG95"="ULG 95","ULG 95"="ULG 95","ULG95R : UNL"="ULG 95","ULG"="ULG 95",
  "GASOHOL95 E10"="GASOHOL 95","GASOHOL 95"="GASOHOL 95","GASOHOL95"="GASOHOL 95",
  "GASOHOL91"="GASOHOL 91","GASOHOL 91"="GASOHOL 91",
  "GASOHOL95 E20"="GASOHOL95 E20","GASOHOL95 E85"="GASOHOL95 E85",
  "LPG (BAHT/KILOGRAM)"="LPG","LPG"="LPG",
  "FO 1500 (2) 2%S"="FO 1500","FO 1500 2%S"="FO 1500",
  "FO 600 (1) 2%S"="FO 600","FO 600 2%S"="FO 600"
)
SKIP_PRODUCTS <- c("H-DIESEL B20","H-DIESEL 20","H-DIESEL B 20")

make_doc_id <- function(base_product, field) {
  p <- base_product |> str_replace_all("[^A-Za-z0-9]+","_") |>
    str_replace_all("_+","_") |> str_remove("^_|_$") |> toupper()
  paste0("EPPO_", p, "_", field)
}

resolve_base <- function(product_name) {
  clean <- str_squish(product_name)
  if (clean %in% SKIP_PRODUCTS) return(NULL)
  base <- PRODUCT_TO_BASE[[clean]]
  if (is.null(base)) { message(sprintf("  ⚠ Unknown: '%s'", clean)); return(NULL) }
  base
}

thai_month <- c(
  "มกราคม"=1,"กุมภาพันธ์"=2,"มีนาคม"=3,"เมษายน"=4,"พฤษภาคม"=5,"มิถุนายน"=6,
  "กรกฎาคม"=7,"สิงหาคม"=8,"กันยายน"=9,"ตุลาคม"=10,"พฤศจิกายน"=11,"ธันวาคม"=12
)
parse_thai_date <- function(txt) {
  m <- str_match(str_trim(txt), "(\\d{1,2})\\s+([ก-์]+)\\s+(\\d{4})")
  if (is.na(m[1])) return(NA_character_)
  day <- as.integer(m[2]); mon <- thai_month[m[3]]; year <- as.integer(m[4]) - 543
  if (is.na(mon) || is.na(year)) return(NA_character_)
  as.character(as.Date(sprintf("%04d-%02d-%02d", year, mon, day)))
}

# วันที่ในไฟล์ ฐานะกองทุน อาจเป็นเดือนเต็ม ("5 กรกฎาคม 2569") หรือย่อมีจุด ("5 ก.ค. 69")
# และปี พ.ศ. อาจเป็น 2 หรือ 4 หลัก
THAI_MONTH_SHORT <- c(
  "ม.ค."=1,"ก.พ."=2,"มี.ค."=3,"เม.ย."=4,"พ.ค."=5,"มิ.ย."=6,
  "ก.ค."=7,"ส.ค."=8,"ก.ย."=9,"ต.ค."=10,"พ.ย."=11,"ธ.ค."=12
)
parse_thai_date_flex <- function(txt) {
  m <- str_match(str_squish(txt), "(\\d{1,2})\\s+([ก-๙\\.]+)\\s+(\\d{2,4})")
  if (is.na(m[1])) return(NA_character_)
  day     <- as.integer(m[2])
  mon     <- thai_month[m[3]] %||% NA_integer_
  if (is.na(mon)) mon <- THAI_MONTH_SHORT[m[3]] %||% NA_integer_
  year_be <- as.integer(m[4])
  year    <- (if (year_be < 100) year_be + 2500 else year_be) - 543
  if (is.na(mon) || is.na(year)) return(NA_character_)
  as.character(as.Date(sprintf("%04d-%02d-%02d", year, mon, day)))
}

do_get <- function(url) {
  request(url) |>
    req_headers("User-Agent"="Mozilla/5.0 (Windows NT 10.0; Win64; x64)") |>
    req_timeout(30) |> req_error(is_error=\(r) FALSE) |> req_perform()
}

# ── Firestore auth ────────────────────────────────────────────────
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

# upsert: GET existing → merge (new overwrite existing by date) → PATCH
# track_change: ถ้า TRUE จะเทียบค่าล่าสุดใน new_df กับค่าของวันก่อนหน้าที่มีอยู่เดิม
# ใน Firestore แล้ว ถ้าต่างกันจะคืนค่ามาใน $change เพื่อเอาไป log/แจ้งเตือน
upsert_series <- function(token, doc_id, name, new_df, track_change = FALSE) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )
  # GET existing points
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

  change <- NULL
  if (track_change && nrow(new_df) > 0) {
    latest_date <- max(new_df$date)
    latest_val  <- new_df$value[new_df$date == latest_date][1]
    prior <- existing_df |> filter(date < latest_date) |> arrange(desc(date)) |> slice(1)
    if (nrow(prior) == 1 && !is.na(prior$value) && prior$value != latest_val) {
      change <- list(date=latest_date, old=prior$value, new=latest_val)
    }
  }

  # merge: new_df overwrite existing on same date
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

  # updateMask จำกัดเฉพาะ name/updated/data — กัน field "meta" (ตั้งโดย
  # push_meta_only.R แยกต่างหาก) ไม่ให้ถูกลบทิ้งเวลา PATCH ทับทั้ง document
  resp <- request(url) |>
    req_url_query(`updateMask.fieldPaths`=c("name","updated","data"), .multi="explode") |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()

  if (resp_status(resp) >= 300) {
    warning(sprintf("  ✗ %s HTTP %d", doc_id, resp_status(resp)))
    return(list(ok=FALSE, change=NULL))
  }
  message(sprintf("  ✓ %s (+%d pts upserted)", doc_id, nrow(new_df)))
  list(ok=TRUE, change=change)
}

# ── Dynamic column/row detection ────────────────────────────────────
# หาตำแหน่งคอลัมน์จาก "หัวตาราง" (label text) แทนการ hardcode index ตายตัว —
# ทนต่อการที่ต้นทางแทรก/สลับคอลัมน์กลางตาราง (เช่น OFFO เพิ่มคอลัมน์ DISCOUNT
# กลางตารางตั้งแต่ไฟล์ 9 ก.ค. 2569 ทำให้ทุกคอลัมน์หลังจากนั้นเลื่อนขวา 1 ช่อง)
find_field_columns <- function(ws, header_rows = 1:6) {
  hr <- header_rows[header_rows <= nrow(ws)]
  col_text <- map_chr(seq_len(ncol(ws)), function(c) {
    vals <- map_chr(hr, function(r) { v <- as.character(ws[r, c]); if (is.na(v)) "" else v })
    str_to_upper(str_squish(paste(vals, collapse = " ")))
  })
  cols <- list(); vat_seen <- 0
  for (c in seq_along(col_text)) {
    txt <- col_text[c]
    if (txt == "") next
    if (is.null(cols$EX_REFIN) && str_detect(txt, "EX.?REFIN"))         { cols$EX_REFIN <- c; next }
    if (is.null(cols$EXCISE_TAX) && str_detect(txt, "EXCISE"))          { cols$EXCISE_TAX <- c; next }
    if (is.null(cols$M_TAX) && str_detect(txt, "M\\.?\\s*TAX"))         { cols$M_TAX <- c; next }
    if (is.null(cols$CONSV_FUND) && str_detect(txt, "CONSV"))           { cols$CONSV_FUND <- c; next }
    if (is.null(cols$WHOLESALE) && str_detect(txt, "WHOLESALE"))        { cols$WHOLESALE <- c; next }
    if (is.null(cols$MARKETING_MARGIN) && str_detect(txt, "MARKETING")) { cols$MARKETING_MARGIN <- c; next }
    if (is.null(cols$RETAIL) && str_detect(txt, "RETAIL"))              { cols$RETAIL <- c; next }
    if (is.null(cols$OIL_FUND) && str_detect(txt, "\\bOIL\\b") && !str_detect(txt, "WHOLESALE")) {
      cols$OIL_FUND <- c; next
    }
    if (str_detect(txt, "\\bVAT\\b") && !str_detect(txt, "WS.?VAT")) {
      vat_seen <- vat_seen + 1
      if (vat_seen == 1) cols$VAT_WS <- c else if (vat_seen == 2) cols$VAT_MM <- c
      next
    }
  }
  cols
}

# แถวข้อมูลแรก = แถวแรกที่คอลัมน์ EX_REFIN เป็นตัวเลข และคอลัมน์ 1 (ชื่อสินค้า) ไม่ว่าง
find_data_start <- function(ws, exrefin_col, max_row = 40) {
  for (r in 2:min(max_row, nrow(ws))) {
    v <- suppressWarnings(as.numeric(as.character(ws[r, exrefin_col])))
    p <- str_squish(as.character(ws[r, 1]))
    if (!is.na(v) && !is.na(p) && p != "" && p != "NA") return(r)
  }
  NA_integer_
}

find_exrate <- function(ws) {
  hit <- which(apply(ws, 1, function(row) any(str_detect(row, "(?i)Exchange\\s*Rate|อัตราแลกเปลี่ยน"), na.rm=TRUE)))
  if (length(hit) == 0) return(NA_real_)
  row_text <- as.character(ws[hit[1], ])
  m <- str_extract(row_text, "\\d{2}\\.\\d+")
  suppressWarnings(as.numeric(m[!is.na(m)][1]))
}

# parse xlsx → df rows (shared by OFFO and EPPO)
# meta_products: base product ทั้งหมดที่เคยเจอ (จาก meta/eppo_status)
# strict: EPPO (authoritative) ต้องมีครบ ไม่งั้น skip ทั้งไฟล์เหมือนเดิม
#         OFFO (fast source) ไม่ต้องครบก็ได้ — บางวันปรับราคาเฉพาะบางผลิตภัณฑ์
#         (เช่น ไม่รวม LPG/FO) จึง push เท่าที่มีในไฟล์ พร้อม warn เฉย ๆ
parse_xlsx <- function(tmp, web_date, meta_products = NULL, strict = TRUE) {
  ws <- tryCatch(
    read_xlsx(tmp, col_names=FALSE, col_types="text", sheet="Oil Price Structure"),
    error=function(e) tryCatch(
      read_xlsx(tmp, col_names=FALSE, col_types="text", sheet=1),
      error=function(e2) { message("  ✗ read_xlsx: ", e2$message); NULL }
    )
  )
  if (is.null(ws)) return(NULL)

  cols <- find_field_columns(ws)
  # HEADER_MISMATCH: หาคอลัมน์หลัก (EX_REFIN/RETAIL) จากหัวตารางไม่เจอเลย หรือหา
  # แถวข้อมูลเริ่มต้นไม่เจอ — แปลว่าต้นทางเปลี่ยน layout เกินกว่าจะเดาอัตโนมัติได้
  # (ดู log บรรทัดนี้ประกอบ — จะได้อีเมลแจ้งอัตโนมัติ)
  if (is.null(cols$EX_REFIN) || is.null(cols$RETAIL)) {
    message(sprintf("  ✗ HEADER_MISMATCH [%s]: หาคอลัมน์ EX_REFIN/RETAIL จากหัวตารางไม่เจอ — skip", web_date))
    return(NULL)
  }
  data_start <- find_data_start(ws, cols$EX_REFIN)
  if (is.na(data_start)) {
    message(sprintf("  ✗ HEADER_MISMATCH [%s]: หาแถวข้อมูลเริ่มต้นไม่เจอ — skip", web_date))
    return(NULL)
  }
  data_end <- min(data_start + 30, nrow(ws))
  exrate   <- find_exrate(ws)

  rows <- list()
  for (r in data_start:data_end) {
    product <- str_squish(as.character(ws[r, 1]))
    if (is.na(product) || product == "" || product == "NA") next
    base <- resolve_base(product)
    if (is.null(base)) next
    row_data <- list(DATE=as.character(web_date), PRODUCT_CLEAN=product,
                     BASE_PRODUCT=base, EX_RATE=exrate)
    for (field in names(cols)) {
      row_data[[field]] <- suppressWarnings(as.numeric(as.character(ws[r, cols[[field]]])))
    }
    rows[[length(rows)+1]] <- row_data
  }
  if (length(rows) == 0) return(NULL)
  df <- bind_rows(rows)

  # เช็คว่า product ที่ resolve ได้ครบตาม meta_products ไหม
  if (!is.null(meta_products)) {
    missing <- setdiff(meta_products, unique(df$BASE_PRODUCT))
    if (length(missing) > 0) {
      if (strict) {
        message(sprintf("  ✗ [%s] missing products: %s — skip ทั้งไฟล์",
                        web_date, paste(missing, collapse=", ")))
        return(NULL)
      }
      message(sprintf("  ⚠ [%s] products not in this file (partial update, ok): %s",
                      web_date, paste(missing, collapse=", ")))
    }
  }

  df
}

# scrape list → pending list(date, href)
scrape_list <- function(base_url, get_pairs_fn, last_date) {
  pending <- list()
  for (page in 0:(MAX_PAGES-1)) {
    url  <- if (page == 0) base_url else paste0(base_url, get_pairs_fn$page_suffix(page))
    resp <- do_get(url)
    if (resp_status(resp) != 200) { message("  HTTP ", resp_status(resp), " — stop"); break }
    html  <- resp_body_string(resp) |> read_html()
    pairs <- get_pairs_fn$extract(html)
    if (length(pairs) == 0) { message("  no items — stop"); break }
    done <- FALSE
    for (pair in pairs) {
      # extractor อาจส่ง date_txt เป็น thai text (EPPO) หรือ ISO string (OFFO)
      raw <- pair$date_txt
      wd_str <- if (grepl("^\\d{4}-\\d{2}-\\d{2}$", raw)) raw else parse_thai_date(raw)
      if (is.na(wd_str)) next
      wd <- as.Date(wd_str)
      if (is.na(wd)) next
      if (wd <= last_date) { done <- TRUE; break }
      pending[[length(pending)+1]] <- list(date=wd, href=pair$href)
    }
    message(sprintf("  page %d: %d items, %d pending", page, length(pairs), length(pending)))
    if (done) break
    Sys.sleep(DELAY)
  }
  rev(pending)  # เรียงเก่า → ใหม่
}

# ── EPPO: probe URL ตรงตามวันที่ (www.eppo.go.th ไม่มีหน้า list ให้ scrape แล้ว —
# ต้องกรอกฟอร์มค้นหาช่วงวันที่ถึงจะเห็นลิงก์ ซึ่งเป็น JS/AJAX scrape ไม่ได้ตรงๆ)
# URL ไฟล์เป็น pattern คงที่ตามวันที่ ("pt-price-st-{Y}-{M}-{D}.xlsx") — ลองทั้งแบบ
# ไม่ใส่ศูนย์นำหน้ากับใส่ศูนย์นำหน้าเผื่อ format ไม่คงที่ทุกเดือน
eppo_candidate_urls <- function(d) {
  y       <- format(d, "%Y")
  m_dir   <- format(d, "%m")
  m_num   <- as.character(as.integer(format(d, "%m")))
  day_num <- as.character(as.integer(format(d, "%d")))
  day_pad <- format(d, "%d")
  unique(c(
    sprintf("%s/%s/%s/pt-price-st-%s-%s-%s.xlsx", EPPO_FILE_BASE, y, m_dir, y, m_num, day_num),
    sprintf("%s/%s/%s/pt-price-st-%s-%s-%s.xlsx", EPPO_FILE_BASE, y, m_dir, y, m_dir, day_pad)
  ))
}

# ไล่ probe ทีละวันจาก last_date+1 ถึงวันนี้ (ไม่มี pagination ให้ walk เหมือน scrape_list)
eppo_scrape_pending <- function(last_date, today = Sys.Date()) {
  pending <- list()
  d <- last_date + 1
  while (d <= today) {
    for (u in eppo_candidate_urls(d)) {
      resp <- do_get(u)
      if (resp_status(resp) == 200) {
        pending[[length(pending)+1]] <- list(date=d, href=u)
        break
      }
    }
    d <- d + 1
  }
  pending
}

# ── EPPO REST API: แหล่งหลัก เช็ค/ดึงวันล่าสุดตรง ๆ เป็น JSON ──────────────
# API นี้เป็นตัวเดียวกับที่หน้าเว็บ (data-energy-statistic/.../โครงสร้างราคาน้ำมัน-LPG)
# เรียกใช้ตอนกดค้นหา — คืนแค่ snapshot ล่าสุดวันเดียว (ไม่รองรับ date range/query param)
fetch_eppo_api_latest <- function() {
  resp <- do_get(EPPO_API_URL)
  if (resp_status(resp) != 200) { message("  ✗ EPPO API HTTP ", resp_status(resp)); return(NULL) }
  d <- tryCatch(resp_body_json(resp), error=function(e) NULL)
  if (is.null(d) || is.null(d$last_updated)) { message("  ✗ EPPO API response ผิดรูปแบบ"); return(NULL) }
  list(
    last_updated = as.Date(d$last_updated),
    file_path    = d$file_path %||% NA_character_,
    labels       = d$structure_label,
    prices       = d$structure_price
  )
}

# แปลง structure_label (key→label text) + structure_price (row keyed ด้วย "1".."13")
# จาก API ให้เป็น df แบบเดียวกับที่ parse_xlsx คืน — หาคอลัมน์จาก label text เหมือนกับ
# find_field_columns() แต่อ่านจาก JSON labels แทนเซลล์ในตาราง
eppo_api_to_df <- function(api, web_date) {
  if (is.null(api$prices) || length(api$prices) == 0) return(NULL)
  label_map <- map_chr(api$labels, \(x) str_to_upper(str_squish(x$label %||% "")))
  names(label_map) <- map_chr(api$labels, \(x) as.character(x$key))

  key_for <- function(pattern, exclude = NULL) {
    for (k in names(label_map)) {
      txt <- label_map[[k]]
      if (str_detect(txt, pattern) && (is.null(exclude) || !str_detect(txt, exclude))) return(k)
    }
    NA_character_
  }
  k_exrefin <- key_for("EX.?REFIN")
  k_excise  <- key_for("EXCISE")
  k_mtax    <- key_for("M\\.?\\s*TAX")
  k_oil     <- key_for("\\bOIL\\b", exclude = "WHOLESALE")
  k_consv   <- key_for("CONSV")
  k_ws      <- key_for("WHOLESALE")
  k_mktmgn  <- key_for("MARKETING")
  k_retail  <- key_for("RETAIL")
  vat_keys  <- names(label_map)[str_detect(label_map, "\\bVAT\\b") & !str_detect(label_map, "WS.?VAT")]
  k_vatws <- vat_keys[1] %||% NA_character_
  k_vatmm <- vat_keys[2] %||% NA_character_

  getval <- function(row, k) {
    if (is.na(k) || is.null(row[[k]]) || row[[k]] == "") return(NA_real_)
    suppressWarnings(as.numeric(row[[k]]))
  }

  rows <- map(api$prices, function(row) {
    product <- str_squish(row[["1"]] %||% "")
    if (product == "") return(NULL)
    base <- resolve_base(product)
    if (is.null(base)) return(NULL)
    list(
      DATE=as.character(web_date), PRODUCT_CLEAN=product, BASE_PRODUCT=base, EX_RATE=NA_real_,
      EX_REFIN=getval(row,k_exrefin), EXCISE_TAX=getval(row,k_excise), M_TAX=getval(row,k_mtax),
      OIL_FUND=getval(row,k_oil), CONSV_FUND=getval(row,k_consv), WHOLESALE=getval(row,k_ws),
      VAT_WS=getval(row,k_vatws), MARKETING_MARGIN=getval(row,k_mktmgn), VAT_MM=getval(row,k_vatmm),
      RETAIL=getval(row,k_retail)
    )
  })
  rows <- compact(rows)
  if (length(rows) == 0) return(NULL)
  bind_rows(rows)
}

# นับจำนวน "วันทำการ" (จ-ศ) ตั้งแต่ from_date (ไม่รวม) ถึง to_date (รวม) — ใช้เช็คว่า
# ข้อมูล lag เกินเกณฑ์จริงไหมโดยไม่นับวันเสาร์-อาทิตย์เป็นวัน lag (EPPO บางทีก็ไม่ลง
# ข้อมูลวันหยุด ซึ่งยอมรับได้)
count_weekdays_between <- function(from_date, to_date) {
  if (is.na(from_date) || is.na(to_date) || to_date <= from_date) return(0)
  days <- seq(from_date + 1, to_date, by = "day")
  # ใช้ $wday (0=อาทิตย์..6=เสาร์) แทน weekdays() เพราะ weekdays() ขึ้นกับ locale
  # ของเครื่อง (เช่น locale ไทยจะได้ "จันทร์" ไม่ใช่ "Monday" — เทียบสตริงพังเงียบๆ)
  wday <- as.POSIXlt(days)$wday
  sum(!wday %in% c(0, 6))
}

offo_extractor <- list(
  page_suffix = function(p) paste0("?page=", p),
  extract = function(html) {
    rows <- html |> html_elements("table tr")
    pairs <- list()
    for (row in rows) {
      href <- row |> html_element("td a") |> html_attr("href")
      alt  <- row |> html_element("td a img") |> html_attr("alt")
      if (is.na(href) || is.na(alt)) next
      # วันที่ราคามีผลอยู่ใน alt: "... วันที่ 7 กรกฎาคม 2569"
      eff <- parse_thai_date(alt)
      if (is.na(eff)) next   # ไม่ใช่ data row — ข้าม
      full_href <- if (startsWith(href,"http")) href else paste0("https://www.offo.or.th", href)
      pairs[[length(pairs)+1]] <- list(date_txt=eff, href=full_href)
    }
    pairs
  }
)

# download pending → parse → df
download_and_parse <- function(pending, meta_products = NULL, strict = TRUE) {
  all_rows <- list()
  latest   <- NULL
  for (item in pending) {
    message(sprintf("  [%s]", item$date))
    resp <- do_get(item$href)
    if (resp_status(resp) != 200) { message("  ✗ HTTP ", resp_status(resp)); next }
    tmp <- tempfile(fileext=".xlsx")
    writeBin(resp_body_raw(resp), tmp)
    df <- parse_xlsx(tmp, item$date, meta_products, strict = strict)
    unlink(tmp)
    if (is.null(df)) next
    all_rows <- c(all_rows, list(df))
    latest   <- item$date
    message(sprintf("  ✓ parsed"))
    Sys.sleep(DELAY)
  }
  list(df=if (length(all_rows)>0) bind_rows(all_rows) else NULL, latest=latest)
}

# ── Oil Fund status (ฐานะกองทุนน้ำมันเชื้อเพลิง) ────────────────────
# หน้านี้ไม่มี pagination — แสดงรายการของปีปัจจุบันทั้งหมดในหน้าเดียว
# วันที่ (ณ วันที่ ...) อยู่ใน text ของ <a> เอง ไม่ต้องงมหา parent node
fund_scrape_pending <- function(last_date) {
  resp <- do_get(FUND_STATUS_LIST)
  if (resp_status(resp) != 200) { message("  HTTP ", resp_status(resp), " — stop"); return(list()) }
  html  <- resp_body_string(resp) |> read_html()
  nodes <- html |> html_elements("a[href*='.pdf'], a[href*='.png'], a[href*='.jpg'], a[href*='.jpeg']")
  pending <- list()
  for (node in nodes) {
    wd_str <- parse_thai_date_flex(html_text(node, trim=TRUE))
    if (is.na(wd_str)) next
    wd <- as.Date(wd_str)
    if (is.na(wd) || wd <= last_date) next
    pending[[length(pending)+1]] <- list(date=wd, href=html_attr(node, "href"))
  }
  pending[order(map_dbl(pending, \(x) as.numeric(x$date)))]
}

# ดาวน์โหลด pdf → อ่านค่า ฐานะกองทุนสุทธิ (net_oil, net_lpg, net_total)
parse_fund_pdf <- function(href) {
  resp <- do_get(href)
  if (resp_status(resp) != 200) { message("  ✗ HTTP ", resp_status(resp)); return(NULL) }
  tmp <- tempfile(fileext=".pdf")
  writeBin(resp_body_raw(resp), tmp)
  text <- tryCatch(pdf_text(tmp) |> paste(collapse="\n"), error=function(e) NA_character_)
  unlink(tmp)
  if (is.na(text)) { message("  ✗ pdf_text failed"); return(NULL) }
  m <- str_match(text, "ฐานะกองทุน\\s*สุทธิ\\s+(-?[\\d,]+)\\s+(-?[\\d,]+)\\s+(-?[\\d,]+)")
  if (is.na(m[1])) { message("  ✗ net fund pattern not found"); return(NULL) }
  list(
    net_oil   = as.numeric(str_remove_all(m[2], ",")),
    net_lpg   = as.numeric(str_remove_all(m[3], ",")),
    net_total = as.numeric(str_remove_all(m[4], ","))
  )
}

# base product + field ที่อยากได้แจ้งเตือนทางเมลเมื่อราคาล่าสุดเปลี่ยนจากวันก่อนหน้า
PRICE_ALERT <- list(DIESEL="RETAIL", `GASOHOL 95`="RETAIL")

# push df to Firestore via upsert
push_df <- function(token, df) {
  ok <- 0
  for (base in unique(df$BASE_PRODUCT)) {
    df_prod <- df |> filter(BASE_PRODUCT==base) |> arrange(DATE) |> distinct(DATE, .keep_all=TRUE)
    for (field in ALL_FIELDS) {
      if (!field %in% names(df_prod)) next
      df_s <- df_prod |> select(date=DATE, value=all_of(field)) |>
        filter(!is.na(value)) |> mutate(value=as.numeric(value)) |>
        filter(!is.na(value), is.finite(value)) |> distinct(date, .keep_all=TRUE) |> arrange(date)
      if (nrow(df_s) == 0) next
      doc_id <- make_doc_id(base, field)
      track  <- !is.null(PRICE_ALERT[[base]]) && identical(PRICE_ALERT[[base]], field)
      res <- upsert_series(token, doc_id, paste0("EPPO ", base, " — ", field), df_s, track_change = track)
      if (res$ok) ok <- ok+1
      if (!is.null(res$change)) {
        message(sprintf("PRICE_CHANGE: %s %s: %s -> %s (%s)",
                        base, field, res$change$old, res$change$new, res$change$date))
      }
      Sys.sleep(0.1)
    }
  }
  ok
}

update_meta_last_date <- function(token, meta_url, meta, latest_date) {
  meta_fields   <- map_chr(meta$fields$fields$arrayValue$values,   \(v) v$stringValue)
  meta_products <- map_chr(meta$fields$products$arrayValue$values, \(v) v$stringValue)
  body <- list(fields=list(
    last_date = list(stringValue=as.character(latest_date)),
    fields    = list(arrayValue=list(values=map(as.list(meta_fields),   \(f) list(stringValue=f)))),
    products  = list(arrayValue=list(values=map(as.list(meta_products), \(p) list(stringValue=p)))),
    updated   = list(stringValue=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC"))
  ))
  r <- request(meta_url) |>
    req_url_query(`updateMask.fieldPaths`=c("last_date","fields","products","updated"), .multi="explode") |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  if (resp_status(r) < 300) message(sprintf("  ✓ last_date → %s", latest_date))
  else message(sprintf("  ✗ HTTP %d", resp_status(r)))
}

# PATCH field เดียวแบบจำกัด updateMask — ใช้กัน field อื่นในเอกสารเดียวกันหาย
patch_meta_field <- function(token, url, field_name, value) {
  body <- list(fields = setNames(list(list(stringValue = as.character(value))), field_name))
  r <- request(url) |>
    req_url_query(`updateMask.fieldPaths`=field_name) |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  resp_status(r)
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

meta_url  <- sprintf(
  "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/eppo_status",
  PROJECT_ID
)
meta_resp <- request(meta_url) |> req_auth_bearer_token(token) |>
  req_error(is_error=\(r) FALSE) |> req_perform()
if (resp_status(meta_resp) != 200) stop("meta/eppo_status ไม่พบ — รัน init_eppo_meta.R ก่อน")

meta          <- resp_body_json(meta_resp)
last_date     <- as.Date(meta$fields$last_date$stringValue)
meta_products <- map_chr(meta$fields$products$arrayValue$values, \(v) v$stringValue)
message(sprintf("  last_date = %s", last_date))
message(sprintf("  products  = %s", paste(meta_products, collapse=", ")))

# ── Step 1: OFFO ─────────────────────────────────────────────────
message("\n── OFFO scrape (fast source)...")
offo_pending <- scrape_list(OFFO_LIST, offo_extractor, last_date)
message(sprintf("  %d new file(s) from OFFO", length(offo_pending)))

offo_latest <- last_date
if (length(offo_pending) > 0) {
  result <- download_and_parse(offo_pending, meta_products, strict = FALSE)
  if (!is.null(result$df)) {
    ok <- push_df(token, result$df)
    message(sprintf("── OFFO pushed %d series", ok))
    offo_latest <- result$latest
    update_meta_last_date(token, meta_url, meta, offo_latest)
    # refresh meta สำหรับ EPPO step ถัดไป
    meta_resp <- request(meta_url) |> req_auth_bearer_token(token) |>
      req_error(is_error=\(r) FALSE) |> req_perform()
    meta <- resp_body_json(meta_resp)
  }
}

# ── Step 2: EPPO ─────────────────────────────────────────────────
# EPPO scrape ตั้งแต่ last_date เดิม (ก่อน OFFO) เพื่อ overwrite วันซ้ำด้วย
# 1) เช็ค EPPO REST API ก่อน (แหล่งหลัก — เป็นตัวเดียวกับที่หน้าเว็บ EPPO ใช้แสดงผล)
# 2) probe URL ตรงตามวันที่เสมอสำหรับช่วงที่ขาดหาย เป็น double-check เผื่อ API เอง
#    cache ค้าง/ตอบช้ากว่าไฟล์จริงบนเว็บ
message("\n── EPPO scrape (authoritative source, overwrite)...")

eppo_api <- fetch_eppo_api_latest()
eppo_rows_list <- list()
eppo_latest <- NULL

if (!is.null(eppo_api)) {
  message(sprintf("  EPPO API last_updated = %s (ไฟล์: %s)",
                  eppo_api$last_updated, basename(eppo_api$file_path %||% "")))
  if (!is.na(eppo_api$last_updated) && eppo_api$last_updated > last_date) {
    df_api <- eppo_api_to_df(eppo_api, eppo_api$last_updated)
    if (!is.null(df_api)) {
      eppo_rows_list[[length(eppo_rows_list)+1]] <- df_api
      eppo_latest <- eppo_api$last_updated
      message(sprintf("  ✓ [%s] จาก EPPO API โดยตรง (%d แถว)", eppo_api$last_updated, nrow(df_api)))
    }
  }
} else {
  message("  ⚠ EPPO API ใช้ไม่ได้ — ใช้วิธี probe URL ตรงอย่างเดียว")
}

# double-check ด้วย URL ตรงสำหรับทุกวันที่ขาดหาย (last_date+1 ถึงวันนี้) ไม่ว่า API จะ
# ตอบสำเร็จหรือไม่ก็ตาม — กันกรณี API ตกหล่นบางวันหรือ cache ช้ากว่าไฟล์จริง
eppo_pending <- eppo_scrape_pending(last_date)
if (!is.null(eppo_latest)) eppo_pending <- keep(eppo_pending, \(x) x$date != eppo_latest)
message(sprintf("  %d file(s) to probe via direct URL (นอกเหนือจาก API)", length(eppo_pending)))

if (length(eppo_pending) > 0) {
  result <- download_and_parse(eppo_pending, meta_products)
  if (!is.null(result$df)) {
    eppo_rows_list[[length(eppo_rows_list)+1]] <- result$df
    eppo_latest <- max(c(eppo_latest, result$latest), na.rm = TRUE)
  }
}

if (length(eppo_rows_list) > 0) {
  eppo_df <- bind_rows(eppo_rows_list)
  ok <- push_df(token, eppo_df)
  message(sprintf("── EPPO pushed %d series (overwrote OFFO where dates overlap)", ok))
  # last_date = max ของทั้งสอง
  true_latest <- max(offo_latest, eppo_latest %||% offo_latest)
  update_meta_last_date(token, meta_url, meta, true_latest)
}

# ── Data freshness check (ไม่นับวันเสาร์-อาทิตย์เป็นวัน lag) ─────────────
overall_latest <- max(offo_latest, eppo_latest %||% offo_latest, na.rm = TRUE)
lag_weekdays <- count_weekdays_between(overall_latest, Sys.Date())
message(sprintf("STALE_CHECK: ข้อมูลล่าสุด = %s (วันนี้ %s) — lag %d วันทำการ",
                overall_latest, Sys.Date(), lag_weekdays))
if (lag_weekdays > STALE_WEEKDAY_THRESHOLD) {
  message(sprintf(
    "STALE_ALERT: ข้อมูลราคาน้ำมัน (OFFO/EPPO) ล่าสุดคือ %s ล่าช้ากว่าวันนี้ (%s) เกิน %d วันทำการ (ไม่รวมเสาร์-อาทิตย์) — ตรวจสอบด่วนว่า OFFO/EPPO เปลี่ยนรูปแบบเว็บ/URL อีกหรือไม่",
    overall_latest, Sys.Date(), STALE_WEEKDAY_THRESHOLD))
}

# ── Step 3: Oil Fund status ──────────────────────────────────────
message("\n── Oil Fund status scrape (ฐานะกองทุนน้ำมันเชื้อเพลิง)...")
FUND_SERIES <- list(
  net_oil   = list(doc_id="OFFO_OILFUND_NET_OIL",   name="OFFO Oil Fund — Net Oil (net_oil)"),
  net_lpg   = list(doc_id="OFFO_OILFUND_NET_LPG",   name="OFFO Oil Fund — Net LPG (net_lpg)"),
  net_total = list(doc_id="OFFO_OILFUND_NET_TOTAL", name="OFFO Oil Fund — Net Total (net_total)")
)

fund_meta_url  <- sprintf(
  "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/meta/oilfund_status",
  PROJECT_ID
)
fund_meta_resp <- request(fund_meta_url) |> req_auth_bearer_token(token) |>
  req_error(is_error=\(r) FALSE) |> req_perform()
fund_last_date <- if (resp_status(fund_meta_resp) == 200) {
  as.Date(resp_body_json(fund_meta_resp)$fields$last_date$stringValue)
} else {
  message("  meta/oilfund_status ไม่พบ — จะสร้างใหม่ (default last_date = 2000-01-01)")
  as.Date("2000-01-01")
}
message(sprintf("  last_date = %s", fund_last_date))

fund_pending <- fund_scrape_pending(fund_last_date)
message(sprintf("  %d new file(s)", length(fund_pending)))

if (length(fund_pending) > 0) {
  fund_rows  <- list()
  fund_latest <- fund_last_date
  for (item in fund_pending) {
    message(sprintf("  [%s]", item$date))
    vals <- parse_fund_pdf(item$href)
    if (is.null(vals)) next
    fund_rows[[length(fund_rows)+1]] <- data.frame(
      date=as.character(item$date), net_oil=vals$net_oil,
      net_lpg=vals$net_lpg, net_total=vals$net_total
    )
    fund_latest <- item$date
    message("  ✓ parsed")
    Sys.sleep(DELAY)
  }
  if (length(fund_rows) > 0) {
    fund_df <- bind_rows(fund_rows)
    for (field in names(FUND_SERIES)) {
      s <- FUND_SERIES[[field]]
      df_s <- fund_df |> select(date, value = all_of(field)) |>
        filter(!is.na(value), is.finite(value)) |> distinct(date, .keep_all=TRUE) |> arrange(date)
      if (nrow(df_s) == 0) next
      upsert_series(token, s$doc_id, s$name, df_s)
    }
    fund_meta_body <- list(fields=list(
      last_date = list(stringValue=as.character(fund_latest)),
      updated   = list(stringValue=format(Sys.time(),"%Y-%m-%dT%H:%M:%SZ",tz="UTC"))
    ))
    fund_meta_patch <- request(fund_meta_url) |> req_method("PATCH") |>
      req_auth_bearer_token(token) |>
      req_body_json(fund_meta_body, auto_unbox=TRUE) |>
      req_error(is_error=\(r) FALSE) |> req_perform()
    if (resp_status(fund_meta_patch) < 300) message(sprintf("  ✓ oilfund last_date → %s", fund_latest))
    else message(sprintf("  ✗ meta patch HTTP %d", resp_status(fund_meta_patch)))
  }
}

# ── Step 4: Daily report gating ──────────────────────────────────
# ส่ง summary email (สถานะ OFFO/EPPO + STALE_ALERT ถ้ามี) แค่รอบแรกของแต่ละวัน —
# เทียบ meta/eppo_status.last_report_date (UTC) กับวันนี้ ถ้าต่างกันคือรอบแรก
# print marker "DAILY_REPORT_DUE: true/false" ให้ workflow grep ไปตัดสินใจส่งเมล
message("\n── Daily report check...")
today_str         <- as.character(Sys.Date())
last_report_date  <- tryCatch(meta$fields$last_report_date$stringValue, error=function(e) NULL) %||% ""
is_first_run_today <- last_report_date != today_str
message(sprintf("DAILY_REPORT_DUE: %s (last_report_date=%s, today=%s)",
                tolower(as.character(is_first_run_today)), last_report_date, today_str))
if (is_first_run_today) {
  status <- patch_meta_field(token, meta_url, "last_report_date", today_str)
  if (status < 300) message("  ✓ last_report_date → ", today_str)
  else message(sprintf("  ✗ patch last_report_date HTTP %d", status))
}

message(sprintf("\n✓ Done"))
