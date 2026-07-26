# ══════════════════════════════════════════════════════════════════
#  fetch_eppo_api.R
#  ดึงโครงสร้างราคาน้ำมัน (EX_REFIN, RETAIL ฯลฯ) จาก EPPO REST API ตรงๆ
#  (ตัวเดียวกับที่หน้าเว็บ eppo.go.th เรียกใช้แสดงผล) — ไม่ scrape xlsx/OFFO
#  เหมือน fetch_eppo.R เดิม เพราะ API คืนแค่ snapshot ล่าสุดวันเดียวอยู่แล้ว
#  รัน: Rscript fetch_eppo_api.R
# ══════════════════════════════════════════════════════════════════

.libPaths(c("/home/runner/R-pkgs", .libPaths()))

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(stringr); library(purrr)
})

# ── Config ────────────────────────────────────────────────────────
PROJECT_ID  <- "macroindicator-6b265"
COLLECTION  <- "series"
EPPO_API_URL <- "https://www.eppo.go.th/wp-json/oil-api/v1/oil-structure-prices"

ALL_FIELDS <- c("EX_REFIN","EXCISE_TAX","M_TAX","OIL_FUND","CONSV_FUND",
                "VAT_WS","MARKETING_MARGIN","VAT_MM","RETAIL","WHOLESALE","EX_RATE","DISCOUNT")

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
upsert_series <- function(token, doc_id, name, new_df) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
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
    warning(sprintf("  ✗ %s HTTP %d", doc_id, resp_status(resp)))
    return(FALSE)
  }
  message(sprintf("  ✓ %s (+%d pts upserted)", doc_id, nrow(new_df)))
  TRUE
}

# ── EPPO REST API ─────────────────────────────────────────────────
fetch_eppo_api_latest <- function() {
  resp <- do_get(EPPO_API_URL)
  if (resp_status(resp) != 200) { message("  ✗ EPPO API HTTP ", resp_status(resp)); return(NULL) }
  d <- tryCatch(resp_body_json(resp), error=function(e) NULL)
  if (is.null(d) || is.null(d$last_updated)) { message("  ✗ EPPO API response ผิดรูปแบบ"); return(NULL) }
  list(
    last_updated = as.Date(d$last_updated),
    labels       = d$structure_label,
    prices       = d$structure_price
  )
}

# แปลง structure_label (key→label text) + structure_price (row keyed ด้วย "1".."13")
# เป็น df โดยหาคอลัมน์จาก label text (ทนต่อการที่ EPPO สลับ/แทรกคอลัมน์กลางตาราง)
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
  k_discount <- key_for("DISCOUNT")
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
      DATE=as.character(web_date), BASE_PRODUCT=base,
      EX_REFIN=getval(row,k_exrefin), DISCOUNT=getval(row,k_discount),
      EXCISE_TAX=getval(row,k_excise), M_TAX=getval(row,k_mtax),
      OIL_FUND=getval(row,k_oil), CONSV_FUND=getval(row,k_consv), WHOLESALE=getval(row,k_ws),
      VAT_WS=getval(row,k_vatws), MARKETING_MARGIN=getval(row,k_mktmgn), VAT_MM=getval(row,k_vatmm),
      RETAIL=getval(row,k_retail)
    )
  })
  rows <- compact(rows)
  if (length(rows) == 0) return(NULL)
  bind_rows(rows)
}

# push df to Firestore via upsert (1 series ต่อ base_product x field)
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
      if (upsert_series(token, doc_id, paste0("EPPO ", base, " — ", field), df_s)) ok <- ok+1
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

meta      <- resp_body_json(meta_resp)
last_date <- as.Date(meta$fields$last_date$stringValue)
message(sprintf("  last_date = %s", last_date))

message("\n── EPPO REST API...")
api <- fetch_eppo_api_latest()
if (is.null(api)) stop("ดึง EPPO API ไม่สำเร็จ")

message(sprintf("  EPPO API last_updated = %s", api$last_updated))
if (is.na(api$last_updated) || api$last_updated <= last_date) {
  message(sprintf("  ⚠ ไม่มีข้อมูลใหม่กว่า last_date (%s) — ข้าม", last_date))
} else {
  df <- eppo_api_to_df(api, api$last_updated)
  if (is.null(df)) {
    message("  ✗ parse API response ไม่ได้ (ไม่พบ product ที่รู้จัก) — ข้าม")
  } else {
    ok <- push_df(token, df)
    message(sprintf("── pushed %d series", ok))
    update_meta_last_date(token, meta_url, meta, api$last_updated)
  }
}

message(sprintf("\n✓ Done"))
