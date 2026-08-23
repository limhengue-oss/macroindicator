# ══════════════════════════════════════════════════════════════════
#  scripts/oneoff/cleanup_old_imf_docs.R
#  ลบ doc เก่า (doc_id schema เดิม, ก่อน 2026-08-22) ของ 20 IMF multi-dataset
#  (fetch_imf_multi.R/backfill_imf_multi.R family) ที่กลายเป็น "orphan"
#  หลังรัน backfill_imf_multi.R เวอร์ชันใหม่แล้ว (doc_id เปลี่ยนรูปแบบ —
#  ดู R/imf_core.R::imf_build_doc_id)
#
#  ต้องรัน backfill_imf_multi.R (เวอร์ชันใหม่) ให้เสร็จก่อนเสมอ — สคริปต์นี้
#  อ่าน scratch_imf/test_results/backfill_doc_ids.txt (manifest ของ doc_id
#  ใหม่ที่เพิ่ง push สำเร็จ) + backfill_log.csv (สถานะต่อ dataset) เพื่อ
#  ตัดสินว่า doc เก่าตัวไหนปลอดภัยที่จะลบ:
#    - ต้องเป็น IMF_* เท่านั้น (ไม่แตะ BOT/SET/BIS/อื่นๆ — คนละ scope)
#    - ไม่แตะ IMF_{ISO3}_CPI_{00-12} (fetch_imf_cpi.R/GlobalCPI — คนละ family
#      คนละ doc_id scheme ไม่เกี่ยวกับ backfill_imf_multi.R)
#    - ไม่อยู่ใน manifest (แปลว่าไม่ใช่ doc ที่เพิ่งเขียนทับ schema ใหม่)
#    - dataset ของมันต้องมีสถานะ "ok" ใน backfill_log.csv รอบล่าสุด (กันลบ
#      ข้อมูลของ dataset ที่ backfill รอบนี้ fail/no_data — ของเก่าต้องอยู่
#      ต่อจนกว่าจะ backfill สำเร็จจริง)
#
#  ตรวจ field ครบก่อนลบ (ไม่เช็คจำนวน point — ตัดสินใจร่วมกับ user 2026-08-22:
#  ข้อมูลย้อนหลังไม่ต้องเป๊ะ เน้นข้อมูลล่าสุดไปข้างหน้าซึ่ง fetch_imf_multi.R
#  ที่รันประจำจะเติมให้เองอยู่แล้ว)
#
#  Resumable: เขียน progress log ทันทีหลังลบสำเร็จแต่ละ doc — รันซ้ำได้ถ้า
#  หลุดกลางทาง จะข้าม doc ที่ลบไปแล้ว
#
#  Environment variables:
#    GCP_SA_KEY — service account JSON (บังคับ ไม่มี DRY RUN สำหรับสคริปต์นี้
#    เพราะเป็นการลบข้อมูลจริง — ต้องตั้งใจรันเท่านั้น)
#
#  รัน: Rscript scripts/oneoff/cleanup_old_imf_docs.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(readr); library(tibble)
  library(jsonlite); library(stringr); library(httr2); library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"
BASE_URL <- sprintf("https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents", PROJECT_ID)

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY ไม่ได้ตั้งค่า — สคริปต์นี้ลบข้อมูลจริง ต้องตั้งใจรันเท่านั้น ไม่มี DRY RUN mode")
sa <- fromJSON(sa_json)

source("R/firestore.R")

MANIFEST_PATH <- "scratch_imf/test_results/backfill_doc_ids.txt"
LOG_PATH      <- "scratch_imf/test_results/backfill_log.csv"
PROGRESS_PATH <- "scratch_imf/test_results/cleanup_deleted_doc_ids.txt"

if (!file.exists(MANIFEST_PATH)) stop(sprintf("ไม่พบ %s — ต้องรัน backfill_imf_multi.R (เวอร์ชันใหม่) ให้เสร็จก่อน", MANIFEST_PATH))
if (!file.exists(LOG_PATH)) stop(sprintf("ไม่พบ %s — ต้องรัน backfill_imf_multi.R (เวอร์ชันใหม่) ให้เสร็จก่อน", LOG_PATH))

new_doc_ids <- read_lines(MANIFEST_PATH) %>% unique()
message(sprintf("── manifest: %d doc_id ใหม่ (schema 2026-08-22)", length(new_doc_ids)))

log_df <- read_csv(LOG_PATH, show_col_types = FALSE)
ok_datasets <- log_df$dataset_id[log_df$status == "ok" & log_df$n_series > 0]
message(sprintf("── dataset ที่ backfill รอบนี้สำเร็จ (n_series>0): %s", paste(ok_datasets, collapse = ", ")))

already_deleted <- if (file.exists(PROGRESS_PATH)) read_lines(PROGRESS_PATH) %>% unique() else character(0)
message(sprintf("── resume: ลบไปแล้วก่อนหน้า %d doc", length(already_deleted)))

CPI_BY_CATEGORY_RE <- "^IMF_[A-Z0-9]{3,4}_CPI_\\d{2}$"

token <- get_access_token(sa)
token_time <- Sys.time()

# ── list doc_id ทั้งหมดใน collection (mask.fieldPaths=updated กันดึง field
# "data" ซึ่งเป็น array จุดข้อมูลยาวๆ มาโดยไม่จำเป็น — ลด bandwidth มาก)
list_all_doc_ids <- function(token) {
  ids <- character(0)
  page_token <- NULL
  repeat {
    query <- list(pageSize = "300", `mask.fieldPaths` = "updated")
    if (!is.null(page_token)) query$pageToken <- page_token
    resp <- request(paste0(BASE_URL, "/", COLLECTION)) |>
      req_url_query(!!!query) |>
      req_auth_bearer_token(token) |>
      req_error(is_error = \(r) FALSE) |>
      req_perform()
    if (resp_status(resp) >= 300) stop(sprintf("list documents failed: HTTP %d — %s", resp_status(resp), resp_body_string(resp)))
    body <- resp_body_json(resp)
    docs <- body$documents
    if (!is.null(docs)) {
      batch_ids <- vapply(docs, function(d) basename(d$name), character(1))
      ids <- c(ids, batch_ids)
    }
    if (is.null(body$nextPageToken)) break
    page_token <- body$nextPageToken
  }
  ids
}

message("── กำลัง list doc ทั้งหมดใน collection (อาจใช้เวลาสักครู่)...")
all_doc_ids <- list_all_doc_ids(token)
message(sprintf("  พบทั้งหมด %d doc", length(all_doc_ids)))

imf_doc_ids <- all_doc_ids[str_starts(all_doc_ids, "IMF_")]
imf_doc_ids <- imf_doc_ids[!str_detect(imf_doc_ids, CPI_BY_CATEGORY_RE)]
message(sprintf("  IMF_* (ไม่รวม CPI-by-category) = %d doc", length(imf_doc_ids)))

candidates <- setdiff(imf_doc_ids, new_doc_ids)
message(sprintf("  ไม่อยู่ใน manifest ใหม่ (candidate สำหรับลบ) = %d doc", length(candidates)))

# ตัดสินว่า candidate อยู่ dataset ไหน (จาก doc_id: IMF_{ISO3}_{DATASET}_{suffix})
# แล้วเก็บเฉพาะตัวที่ dataset นั้น backfill รอบนี้สำเร็จ (status=="ok") —
# เรียง dataset จากชื่อยาว->สั้นก่อนจับคู่ กัน "CPI" จับ "IMF_xxx_CPI_WCA_..."
# ผิดเป็นของตัวเอง (CPI_WCA ขึ้นต้นด้วย "CPI_" เหมือนกัน ต้องให้ตัวยาวชนะก่อน
# — ปัญหาเดียวกับที่ index.html's IMF_DATASET_RE_ALT เคยแก้ไว้แล้ว)
ok_datasets_sorted <- ok_datasets[order(nchar(ok_datasets), decreasing = TRUE)]
dataset_of <- function(doc_id) {
  hit <- ok_datasets_sorted[str_detect(doc_id, paste0("^IMF_[A-Z0-9]{2,4}_", ok_datasets_sorted, "_"))]
  if (length(hit) == 0) NA_character_ else hit[1]
}
candidate_datasets <- vapply(candidates, dataset_of, character(1))
to_delete <- candidates[!is.na(candidate_datasets)]
skipped_unknown_dataset <- candidates[is.na(candidate_datasets)]

message(sprintf("  ✓ ปลอดภัยที่จะลบ (dataset backfill สำเร็จรอบนี้แล้ว) = %d doc", length(to_delete)))
if (length(skipped_unknown_dataset) > 0) {
  message(sprintf("  ⊘ ข้าม %d doc — dataset ไม่ได้อยู่ในกลุ่ม status=ok รอบนี้ (ปล่อยไว้ก่อน ไม่ลบ)", length(skipped_unknown_dataset)))
}

to_delete <- setdiff(to_delete, already_deleted)
message(sprintf("── เหลือต้องลบจริง (หัก resume แล้ว) = %d doc", length(to_delete)))

if (length(to_delete) == 0) {
  message("ไม่มี doc ต้องลบ — จบการทำงาน")
  quit(status = 0)
}

progress_con <- file(PROGRESS_PATH, open = "a")
BATCH_SIZE <- 200
n <- length(to_delete)
deleted_count <- 0

for (i in seq_len(n)) {
  if (!is.null(token_time) && difftime(Sys.time(), token_time, units = "mins") > 45) {
    message("── Token ใกล้หมดอายุ — ขอ token ใหม่...")
    token <- get_access_token(sa)
    token_time <- Sys.time()
  }
  doc_id <- to_delete[i]
  resp <- request(paste0(BASE_URL, "/", COLLECTION, "/", doc_id)) |>
    req_method("DELETE") |>
    req_auth_bearer_token(token) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform()
  if (resp_status(resp) < 300 || resp_status(resp) == 404) {
    writeLines(doc_id, progress_con)
    flush(progress_con)
    deleted_count <- deleted_count + 1
  } else {
    warning(sprintf("  ✗ ลบ %s ไม่สำเร็จ: HTTP %d", doc_id, resp_status(resp)))
  }
  if (i %% BATCH_SIZE == 0 || i == n) {
    message(sprintf("  ... ลบไปแล้ว %d/%d", i, n))
  }
}
close(progress_con)

message(sprintf("\n✓ Done. ลบสำเร็จ %d/%d doc", deleted_count, n))
