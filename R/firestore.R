# ══════════════════════════════════════════════════════════════════
#  R/firestore.R — Firestore auth + push helpers ที่ใช้ร่วมกันในทุก
#  fetch_*.R script (เดิม copy-paste ซ้ำเหมือนกันเกือบทุกตัวอักษรอยู่ 9
#  ไฟล์: fetch_and_push.R, fetch_bis.R, fetch_bot.R, fetch_goldth.R,
#  fetch_imf.R, fetch_imf_cpi.R, fetch_nesdc.R, fetch_thaibma.R,
#  fetch_tpso.R — รวมมาไว้ที่เดียว)
#  หมายเหตุ 2026-08-16: fetch_imf.R ถูกลบไปแล้ว (ไม่เคย push ข้อมูลจริง)
#  เพิ่ม fetch_imf_multi.R (21 IMF dataset) เป็น consumer ใหม่แทน
#
#  แต่ละสคริปต์ต้อง library(httr2)/library(jose)/library(purrr) เองก่อน
#  source ไฟล์นี้ (ไฟล์นี้ไม่โหลด package ให้ เพื่อไม่ให้ซ้อนกับ
#  suppressPackageStartupMessages บล็อกที่แต่ละสคริปต์มีอยู่แล้ว)
#
#  Usage:
#    source("R/firestore.R")
#    token <- get_access_token(sa)
#    push_series(token, doc_id, name, df, meta = meta)                    # full replace
#    push_series(token, doc_id, name, df, is_incremental = TRUE, meta = meta)  # merge กับของเดิม
# ══════════════════════════════════════════════════════════════════

`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

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

# ผสาน existing points (Firestore mapValue list ที่ GET กลับมา) เข้ากับ
# points ใหม่ เรียงตามวันที่ ตัดวันที่ซ้ำ (เก็บตัวหลังสุดในลิสต์ไว้ — ใช้
# เวลาเอา existing มาต่อ "หน้า" new เสมอ จุดใหม่จึงชนะจุดเก่าเมื่อวันที่ซ้ำ)
dedup_sort_points <- function(pts) {
  if (length(pts) == 0) return(pts)
  dates <- map_chr(pts, \(p) p$mapValue$fields$d$stringValue)
  keep  <- !duplicated(dates, fromLast = TRUE)
  pts   <- pts[keep]
  dates <- dates[keep]
  pts[order(dates)]
}

# ── แปลงค่า R (scalar หรือ named list ซ้อนกันกี่ชั้นก็ได้) เป็น Firestore
# Value แบบ recursive — ใช้กับ meta ที่เพิ่ม nested map เข้ามา (schema ใหม่
# 2026-08-22: meta$country/meta$category/meta$dims เป็น map ซ้อน map)
firestore_encode_value <- function(v) {
  # list() ว่างเปล่า (เช่น dims ของ series ที่ไม่มี sub-item) ต้องเป็น
  # empty map เสมอ ไม่ใช่ string ว่าง — names(list()) คืน NULL ทำให้เงื่อนไข
  # เดิม (!is.null(names(v))) หลุดไปตกที่ stringValue="" ผิดพลาด แก้ด้วยเช็ค
  # length(v)==0 แยกออกมาก่อน
  if (is.list(v) && length(v) == 0) {
    # setNames(list(), character(0)) กัน jsonlite serialize เป็น "[]" (array)
    # แทน "{}" (object) — R list() เปล่าไม่มี names() (NULL) จึง ambiguous,
    # ต้องบังคับ names เป็น character(0) explicit ให้ jsonlite รู้ว่าเป็น object
    list(mapValue = list(fields = setNames(list(), character(0))))
  } else if (is.list(v) && !is.null(names(v)) && all(names(v) != "")) {
    list(mapValue = list(fields = lapply(v, firestore_encode_value)))
  } else if (is.logical(v)) {
    list(booleanValue = isTRUE(v))
  } else {
    list(stringValue = as.character(v %||% ""))
  }
}

#' เขียน series 1 ตัวเข้า Firestore (PATCH, updateMask จำกัดเฉพาะ field ที่
#' ส่งจริง กัน PATCH ทับทั้ง document)
#' @param df tibble(date, value)
#' @param is_incremental FALSE (default) = เขียนทับ data ทั้งก้อนด้วย df ที่ส่งมา
#'   (ใช้เมื่อ df มีข้อมูลเต็มช่วงอยู่แล้ว เช่น bulk refetch) — TRUE = GET
#'   ของเดิมมาก่อน แล้ว merge+dedup กับ df ใหม่ (ใช้เมื่อ df เป็นแค่จุดใหม่
#'   ล่าสุด ไม่ใช่ประวัติทั้งหมด)
#' @param quiet ข้าม success message ต่อ doc (ใช้กับสคริปต์ที่ push จำนวน
#'   มาก เช่น fetch_imf_cpi.R ที่รายงาน progress เป็นก้อนแทน)
push_series <- function(token, doc_id, name, df, is_incremental = FALSE, meta = NULL, quiet = FALSE) {
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
  existing_meta_fields <- NULL
  if (is_incremental) {
    existing_fields <- tryCatch({
      r <- request(url) |> req_auth_bearer_token(token) |>
        req_error(is_error = \(r) FALSE) |> req_perform()
      if (resp_status(r) == 200) resp_body_json(r)$fields else NULL
    }, error = function(e) NULL)
    existing_points <- if (!is.null(existing_fields$data$arrayValue$values)) existing_fields$data$arrayValue$values else list()
    all_points <- dedup_sort_points(c(existing_points, new_points))
    existing_meta_fields <- existing_fields$meta$mapValue$fields
  }

  fields <- list(
    name    = list(stringValue = name),
    updated = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
    data    = list(arrayValue = list(values = all_points))
  )

  # generic: รับ key ไหนก็ได้ใน meta ไม่ใช่แค่ 5 field เดิม (fullName/
  # currency/unit/freq/source) — เผื่อ field เพิ่มเติมเฉพาะ dataset เช่น
  # CPI's recommendedIndexType/isRecommended (ดู R/imf_core.R) ตัวเดิม 5
  # field ยัง output เหมือนเดิมทุกตัวอักษรสำหรับ caller ที่ไม่ได้ส่ง field
  # อื่นมา (backward compatible) — เพิ่ม 2026-08-22: รองรับ nested list ด้วย
  # (recursive) สำหรับ schema ใหม่ meta$country/meta$category/meta$dims ที่
  # เป็น map ซ้อน map (เช่น dims: {INDICATOR: {code,label,role}, ...})
  if (!is.null(meta)) {
    meta_fields <- lapply(meta, firestore_encode_value)
    # updateMask ที่ path "meta" เขียนทับทั้ง map ไม่ใช่ merge ลึก (Firestore
    # field mask ไม่ recurse เข้า map field) — caller ส่วนใหญ่ (fetch_bot.R/
    # fetch_thaibma.R/fetch_goldth.R/ฯลฯ) ไม่รู้จัก/ไม่ได้ตั้งใจส่ง
    # country/category/dims (schema ใหม่ 2026-08-22 เติมทีหลังผ่าน
    # migrate_nonsdmx_categories.R แยกต่างหาก) — ถ้าไม่กันตรงนี้ push
    # ปกติทุกวันของ script พวกนี้จะเขียนทับ 3 field นั้นหายไปเงียบๆ ทุกครั้ง
    # (bug เจอจริง 2026-08-25: THAIBMA_YIELD_1Y หลุดกลับไปใช้ classifySeries()
    # fallback เก่าเพราะ meta.category หายหลัง fetch_thaibma.yml รันรายวัน)
    # — preserve ของเดิมไว้เฉพาะ key ที่ caller ไม่ได้ส่งมาเอง
    for (k in c("country", "category", "dims")) {
      if (is.null(meta_fields[[k]]) && !is.null(existing_meta_fields[[k]])) {
        meta_fields[[k]] <- existing_meta_fields[[k]]
      }
    }
    fields$meta <- list(mapValue = list(fields = meta_fields))
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
  if (!quiet) {
    if (is_incremental) message(sprintf("  ✓ %s (+%d new points)", doc_id, nrow(df)))
    else                message(sprintf("  ✓ %s (%d points)", doc_id, nrow(df)))
  }
  TRUE
}

#' PATCH เฉพาะ field "meta" (updateMask=["meta"] เท่านั้น) — ไม่แตะ
#' name/data/updated เลย ต่างจาก push_series() ที่บังคับเขียนทับ 3 field
#' นั้นทุกครั้งไม่ว่าจะส่ง meta หรือไม่ก็ตาม ใช้กรณี migrate schema (เติม
#' country/category/dims) ให้ series ที่ doc_id ไม่เปลี่ยนและ data มีอยู่แล้ว
#' (BOT/SET/BIS/THAIBMA — ตัดสินใจ 2026-08-23 ระหว่างออกแบบ schema ใหม่)
patch_series_meta <- function(token, doc_id, meta, quiet = FALSE) {
  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, doc_id
  )
  body <- list(fields = list(
    meta = list(mapValue = list(fields = lapply(meta, firestore_encode_value)))
  ))
  resp <- request(url) |>
    req_url_query(`updateMask.fieldPaths` = "meta", .multi = "explode") |>
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
  if (!quiet) message(sprintf("  ✓ %s (meta patched)", doc_id))
  TRUE
}
