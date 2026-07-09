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
EPPO_BASE    <- "https://old.eppo.go.th"
EPPO_LIST    <- paste0(EPPO_BASE, "/index.php/th/petroleum/price/structure-oil-price")
OFFO_LIST    <- "https://www.offo.or.th/th/oil-price-structure-adjusted"
FUND_STATUS_LIST <- "https://www.offo.or.th/th/estimate/fuelfund-status"
MAX_PAGES    <- 3
DELAY        <- 1.0

DATA_START <- 6; DATA_END <- 15
EXRATE_ROW <- 17; EXRATE_COL <- 3

FIELDS_COL <- list(
  EX_REFIN=2, EXCISE_TAX=3, M_TAX=4, OIL_FUND=5, CONSV_FUND=6,
  WHOLESALE=7, VAT_WS=8, MARKETING_MARGIN=10, VAT_MM=11, RETAIL=12
)
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

  resp <- request(url) |> req_method("PATCH") |>
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
  if (is.na(suppressWarnings(as.numeric(as.character(ws[DATA_START, 3]))))) {
    message("  ✗ col3 not numeric — skip"); return(NULL)
  }
  if (ncol(ws) < max(unlist(FIELDS_COL))) {
    message("  ✗ not enough cols — skip"); return(NULL)
  }
  exrate <- suppressWarnings(as.numeric(as.character(ws[EXRATE_ROW, EXRATE_COL])))
  rows <- list()
  for (r in DATA_START:min(DATA_END, nrow(ws))) {
    product <- str_squish(as.character(ws[r, 1]))
    if (is.na(product) || product == "" || product == "NA") next
    base <- resolve_base(product)
    if (is.null(base)) next
    row_data <- list(DATE=as.character(web_date), PRODUCT_CLEAN=product,
                     BASE_PRODUCT=base, EX_RATE=exrate)
    for (field in names(FIELDS_COL)) {
      col_idx <- FIELDS_COL[[field]]
      row_data[[field]] <- if (col_idx <= ncol(ws))
        suppressWarnings(as.numeric(as.character(ws[r, col_idx]))) else NA_real_
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

# ── Source-specific extractors ────────────────────────────────────
eppo_extractor <- list(
  page_suffix = function(p) paste0("?start=", p * 9),
  extract = function(html) {
    dl_nodes <- html |> html_elements("a[href*='download']")
    map(dl_nodes, function(node) {
      list(
        date_txt = node |> xml2::xml_parent() |> xml2::xml_parent() |>
          html_element("div[style*='float:left']") |> html_text(trim=TRUE) %||% "",
        href = paste0(EPPO_BASE, html_attr(node, "href"))
      )
    })
  }
)

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
  r <- request(meta_url) |> req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(body, auto_unbox=TRUE) |>
    req_error(is_error=\(r) FALSE) |> req_perform()
  if (resp_status(r) < 300) message(sprintf("  ✓ last_date → %s", latest_date))
  else message(sprintf("  ✗ HTTP %d", resp_status(r)))
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
message("\n── EPPO scrape (authoritative source, overwrite)...")
eppo_pending <- scrape_list(EPPO_LIST, eppo_extractor, last_date)
message(sprintf("  %d file(s) from EPPO (may overlap with OFFO)", length(eppo_pending)))

eppo_latest <- NULL
if (length(eppo_pending) > 0) {
  result <- download_and_parse(eppo_pending, meta_products)
  if (!is.null(result$df)) {
    ok <- push_df(token, result$df)
    message(sprintf("── EPPO pushed %d series (overwrote OFFO where dates overlap)", ok))
    eppo_latest <- result$latest
    # last_date = max ของทั้งสอง
    true_latest <- max(offo_latest, eppo_latest %||% offo_latest)
    update_meta_last_date(token, meta_url, meta, true_latest)
  }
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

message(sprintf("\n✓ Done"))
