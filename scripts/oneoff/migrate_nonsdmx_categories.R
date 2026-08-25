# ══════════════════════════════════════════════════════════════════
#  scripts/oneoff/migrate_nonsdmx_categories.R
#  เติม country/category/dims (schema ใหม่ 2026-08-22/23) ให้ series กลุ่ม
#  ที่ไม่ใช่ IMF SDMX (BOT, SET/SET_*, BIS_*, THAIBMA_YIELD_*) — ต่างจาก IMF
#  multi-dataset family: doc_id กลุ่มนี้ไม่เปลี่ยน (ไม่มี component/variant
#  ให้ derive-forward) เลยแค่ PATCH field "meta" เข้า doc เดิมตรงๆ ผ่าน
#  patch_series_meta() (ไม่แตะ data/name เลย ต่างจาก push_series())
#
#  ที่มา mapping: ported ตรงจาก classifySeries()/GROUP_MODE ใน index.html
#  (BOT_YIELD_* ถูกตัดออกจากระบบไปแล้วเมื่อ 2026-08-23 — ใช้ THAIBMA_YIELD_*
#  แทน เพราะเป็นข้อมูลชุดเดียวกันแต่รายวัน/ถี่กว่า)
#
#  dims ปล่อยว่างทั้งหมด — กลุ่มนี้ไม่มี sub-item จริงตาม design ที่ตกลงไว้
#
#  Environment variables:
#    GCP_SA_KEY — service account JSON (บังคับ ไม่มี DRY RUN เพราะ PATCH
#    เข้า production Firestore ตรงๆ)
#
#  รัน: Rscript scripts/oneoff/migrate_nonsdmx_categories.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(jsonlite); library(httr2); library(jose)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY ไม่ได้ตั้งค่า — สคริปต์นี้เขียนข้อมูลจริง ต้องตั้งใจรันเท่านั้น")
sa <- fromJSON(sa_json)

source("R/firestore.R")

MAP_PATH <- "data/nonsdmx_category_map.csv"
PROGRESS_PATH <- "scratch_imf/test_results/migrate_nonsdmx_progress.txt"

map_df <- read_csv(MAP_PATH, show_col_types = FALSE)
message(sprintf("── mapping: %d doc_id (BOT/SET/BIS/THAIBMA)", nrow(map_df)))

already_done <- if (file.exists(PROGRESS_PATH)) readLines(PROGRESS_PATH) else character(0)
map_df <- map_df %>% filter(!doc_id %in% already_done)
message(sprintf("── resume: เหลือต้องทำ %d doc (หัก %d ที่ทำไปแล้ว)", nrow(map_df), length(already_done)))

if (nrow(map_df) == 0) {
  message("ไม่มี doc ต้องทำ — จบการทำงาน")
  quit(status = 0)
}

token <- get_access_token(sa)
token_time <- Sys.time()
dir.create(dirname(PROGRESS_PATH), showWarnings = FALSE, recursive = TRUE)
progress_con <- file(PROGRESS_PATH, open = "a")

ok_count <- 0
n <- nrow(map_df)
for (i in seq_len(n)) {
  if (difftime(Sys.time(), token_time, units = "mins") > 45) {
    message("── Token ใกล้หมดอายุ — ขอ token ใหม่...")
    token <- get_access_token(sa)
    token_time <- Sys.time()
  }
  row <- map_df[i, ]
  # patch_series_meta() เขียนทับ field "meta" ทั้งก้อน (ไม่ merge) — ต้อง GET
  # ของเดิมมาก่อนแล้วค่อยแก้เฉพาะ country/category/dims ไม่งั้น fullName/
  # currency/unit/freq/source ที่ script อื่น (fetch_bot.R ฯลฯ) เขียนไว้จะหาย
  # (บั๊กที่เจอจริง 2026-08-23 ตอน rerun ครั้งแรก — แก้ตรงนี้กันไม่ให้ซ้ำ)
  existing_meta <- tryCatch({
    url <- sprintf("https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
                    PROJECT_ID, COLLECTION, row$doc_id)
    r <- request(url) |> req_auth_bearer_token(token) |> req_error(is_error = \(r) FALSE) |> req_perform()
    if (resp_status(r) != 200) return(list())
    fields <- resp_body_json(r)$fields$meta$mapValue$fields
    if (is.null(fields)) return(list())
    lapply(fields, function(f) f$stringValue %||% f$booleanValue %||% NA)
  }, error = function(e) list())
  existing_meta$country <- NULL; existing_meta$category <- NULL; existing_meta$dims <- NULL
  meta <- c(existing_meta, list(
    country  = list(code = row$country_code, label = row$country_label),
    category = list(code = row$category_code, label = row$category_label),
    dims     = list()
  ))
  if (patch_series_meta(token, row$doc_id, meta, quiet = TRUE)) {
    ok_count <- ok_count + 1
    writeLines(row$doc_id, progress_con)
    flush(progress_con)
  }
  if (i %% 20 == 0 || i == n) message(sprintf("  ... %d/%d", i, n))
}
close(progress_con)

message(sprintf("\n✓ Done. patch สำเร็จ %d/%d doc", ok_count, n))
