# ══════════════════════════════════════════════════════════════════
#  splice_and_cleanup_imf_duplicates.R
#  One-time cleanup: บาง IMF dataset มี series ซ้ำ (code variant คนละชุด
#  ความหมายเดียวกัน — ดู CHANGES.md/บทสนทนา 2026-08-26) ตัวหนึ่งมาจาก
#  backfill_imf_multi.R (ประวัติยาว ค้าง ไม่อัปเดตอีก) อีกตัวมาจาก
#  fetch_imf_multi.R (สั้นแค่ ~2 ปี แต่อัปเดตต่อเนื่อง) — script นี้:
#    1. หาคู่ซ้ำจริง (label เดียวกัน ค่าตรงกัน/ตรงกันหลัง normalize SCALE)
#    2. splice: เติมจุดเก่าจากตัวแพ้เข้าตัวชนะ (ไม่ทับจุดที่ overlap)
#    3. ลบตัวแพ้ทิ้ง (เฉพาะตอน DELETE_LOSERS=true เท่านั้น)
#
#  ขอบเขต: 9 dataset ที่ verify แล้วว่าปลอดภัย (ดู DEDUPE_CODE_VARIANT_DATASETS
#  ใน fetch_imf_multi.R) — ห้ามรันกับ MFS_FC (label ซ้ำ ≠ series เดียวกันจริง)
#
#  Environment variables:
#    GCP_SA_KEY     — service account JSON — ไม่ใส่ก็รันได้แต่เป็น DRY RUN
#    DELETE_LOSERS  — "true" เท่านั้นถึงจะลบ doc จริง (default: ไม่ลบ แค่ splice)
#
#  รัน: Rscript scripts/oneoff/splice_and_cleanup_imf_duplicates.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(stringr); library(tibble)
  library(jsonlite); library(httr2); library(jose)
})

# print warning() ทันทีที่เกิด (default ของ Rscript buffer ไว้โชว์แค่ "There
# were 50+ warnings" ตอนจบสคริปต์ ไม่มีรายละเอียด) — เจอจริง 2026-08-28:
# push_series() ล้มเหลวเงียบๆ ~4000 ครั้ง (rate limit) ไม่รู้สาเหตุเพราะ
# warning() ของ push_series()/delete_doc() โดน buffer ไปหมด
options(warn = 1)

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN <- sa_json == ""
DELETE_LOSERS <- Sys.getenv("DELETE_LOSERS", "false") == "true"
if (DRY_RUN) message("── GCP_SA_KEY not set — DRY RUN (ไม่ push/ไม่ลบ ดู log อย่างเดียว)")
if (!DRY_RUN && !DELETE_LOSERS) message("── DELETE_LOSERS != true — จะ splice จริง แต่ไม่ลบตัวแพ้ (รันซ้ำได้ปลอดภัย)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

source("R/firestore.R")
source("R/imf_core.R")

TARGET_DATASETS <- c("CPI", "CTOT", "EER", "ER", "PI", "PPI", "QGDP_WCA", "IL", "ITG", "CPI_WCA")
# รองรับจำกัดเฉพาะ dataset (เช่นตอนเพิ่ม dataset ใหม่เข้า allowlist ไม่ต้อง
# รันซ้ำทั้งก้อน — pattern เดียวกับ IMF_FETCH_DATASETS ใน fetch_imf_multi.R)
subset_env <- Sys.getenv("SPLICE_DATASETS")
if (nzchar(subset_env)) {
  TARGET_DATASETS <- intersect(TARGET_DATASETS, trimws(strsplit(subset_env, ",")[[1]]))
  message(sprintf("── SPLICE_DATASETS set — จำกัดเหลือ: %s", paste(TARGET_DATASETS, collapse = ", ")))
}
REST_BASE <- sprintf("https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents", PROJECT_ID)

# ── ดึง series ทั้งหมดของ dataset หนึ่ง (name+updated+meta+data ครบ ผ่าน
# runQuery ธรรมดา ไม่ projection เพราะต้องใช้ data มา splice ด้วย) —
# ใช้ REST ตรงๆ ไม่ผ่าน token (public read เหมือนที่หน้าเว็บทำ) เพราะแค่
# อ่าน ยังไม่เขียนอะไร
fetch_series_for_dataset <- function(dataset_id) {
  body <- list(structuredQuery = list(
    from = list(list(collectionId = COLLECTION)),
    where = list(fieldFilter = list(
      field = list(fieldPath = "meta.category.code"),
      op = "EQUAL",
      value = list(stringValue = dataset_id)
    )),
    limit = 6000
  ))
  resp <- request(paste0(REST_BASE, ":runQuery")) |>
    req_body_json(body, auto_unbox = TRUE) |>
    req_perform()
  rows <- resp_body_json(resp)
  rows <- Filter(function(r) !is.null(r$document), rows)
  message(sprintf("  %s: %d series", dataset_id, length(rows)))
  rows
}

# ── แปลง Firestore document -> list(id, country, labels(named vec),
# freq, updated, points=data.frame(date,value))
parse_doc <- function(doc) {
  f <- doc$fields
  meta <- f$meta$mapValue$fields
  dims <- meta$dims$mapValue$fields
  labels <- imap(dims, function(d, k) {
    role <- d$mapValue$fields$role$stringValue
    if (!is.null(role) && role %in% c("component", "variant")) {
      d$mapValue$fields$label$stringValue
    } else NA_character_
  })
  labels <- labels[!vapply(labels, is.na, logical(1))]
  # `%||%` เช็ค is.na(x) ซึ่ง error ถ้า x เป็น list ยาวเกิน 1 (data array มี
  # หลายสิบ/ร้อยจุด) — ใช้ is.null() ตรงๆ แทนสำหรับ field นี้เท่านั้น
  pts <- f$data$arrayValue$values
  if (is.null(pts)) pts <- list()
  points <- map_dfr(pts, function(p) {
    ff <- p$mapValue$fields
    val <- ff$v$doubleValue %||% as.numeric(ff$v$integerValue %||% NA)
    tibble(date = ff$d$stringValue, value = val)
  })
  list(
    id = str_extract(doc$name, "[^/]+$"),
    name = f$name$stringValue %||% str_extract(doc$name, "[^/]+$"),
    country = meta$country$mapValue$fields$code$stringValue,
    labels = unlist(labels),
    freq = meta$freq$stringValue %||% "",
    updated = f$updated$stringValue %||% "",
    points = points
  )
}

delete_doc <- function(token, doc_id) {
  url <- sprintf("%s/%s/%s", REST_BASE, COLLECTION, doc_id)
  resp <- request(url) |> req_auth_bearer_token(token) |>
    req_method("DELETE") |> req_error(is_error = \(r) FALSE) |> req_perform()
  status <- resp_status(resp)
  if (status >= 300) {
    warning(sprintf("  ✗ delete %s: HTTP %d", doc_id, status))
    return(FALSE)
  }
  TRUE
}

# ── retry wrapper: รอบก่อนหน้า (2026-08-28) push_series()/delete_doc() ล้มเหลว
# เงียบๆ จำนวนมาก (2038/6204 สำเร็จเท่านั้น) น่าจะเป็น rate limit ชั่วคราว
# จาก sequential GET+PATCH หลายพันครั้งรัว ๆ — ห่อ retry แบบ exponential
# backoff สั้นๆ (3 ครั้ง, 1s/2s/4s) ก่อนยอมแพ้จริง
with_retry <- function(fn, ..., max_tries = 3) {
  for (i in seq_len(max_tries)) {
    ok <- suppressWarnings(fn(...))
    if (isTRUE(ok)) return(TRUE)
    if (i < max_tries) Sys.sleep(2^(i - 1))
  }
  FALSE
}

token <- NULL
if (!DRY_RUN) token <- get_access_token(sa)

total_spliced <- 0
total_deleted <- 0
total_skipped_mismatch <- 0

for (dataset_id in TARGET_DATASETS) {
  message(sprintf("\n══ %s ══", dataset_id))
  rows <- fetch_series_for_dataset(dataset_id)
  if (length(rows) == 0) next
  parsed <- map(rows, function(r) tryCatch(parse_doc(r$document), error = function(e) NULL))
  parsed <- Filter(Negate(is.null), parsed)

  # group key: country + label ของทุก component/variant dim (เรียง key ให้
  # deterministic) — "ไม่รวม freq เข้า key" โดยตั้งใจ (เจอจริง 2026-08-26
  # 2 ปัญหาซ้อนกัน: (1) backfill_imf_multi.R เขียน meta.freq เป็นคำเต็ม
  # "Monthly" ส่วน fetch_imf_multi.R (live) เขียนย่อ "M" — normalize ได้
  # (2) แต่ CTOT/QGDP_WCA backfill กลับเขียน meta.freq เป็น "" (ว่างเปล่า
  # ไปเลย ไม่ใช่แค่เขียนคนละแบบ) — ไม่มีทาง normalize ให้ตรงกับ "M"/"Q" ได้
  # เพราะไม่มีข้อมูลจริงให้ derive) — country+label ของ component/variant
  # dim ทุกตัวเจาะจงพอแล้วอยู่แล้วที่จะระบุ series ได้ไม่กำกวม ไม่จำเป็นต้อง
  # พึ่ง freq เป็นส่วนหนึ่งของ key เลย — กันความเสี่ยง merge ผิด freq ด้วย
  # guard เช็คแยกข้างล่างแทน (ถ้าเจอ freq ไม่ตรงกันจริงในกลุ่มเดียวกัน จะ
  # log เตือนแล้วข้าม ไม่ splice)
  normalize_freq <- function(f) {
    f <- toupper(trimws(f))
    if (f %in% c("M", "MONTHLY")) return("M")
    if (f %in% c("Q", "QUARTERLY")) return("Q")
    if (f %in% c("A", "ANNUAL", "YEARLY")) return("A")
    f
  }
  key_of <- function(p) {
    lbls <- p$labels
    # CPI_WCA: บาง doc (backfill เก่า) มีแค่ TYPE_OF_TRANSFORMATION dim
    # ตัวเดียว ไม่มี COICOP_1999/INDEX_TYPE เลย (headline-only aggregate
    # ไม่มี breakdown ให้ตั้งแต่ต้น) ส่วน doc ใหม่ (live fetch) กลับมี
    # ครบ 3 dim — ถ้าใช้ label ทุก dim เป็น key ตรงๆ 2 doc นี้จะได้ key
    # ไม่ตรงกันเลย ทั้งที่เป็น series เดียวกัน (verify แล้ว 2026-09-04:
    # ค่าตรงกันทุกจุด) — ตัด COICOP_1999/INDEX_TYPE ออกจาก key เฉพาะ
    # dataset นี้ เหลือแค่ TYPE_OF_TRANSFORMATION พอ (เหมือนที่
    # getInflationIndex() ฝั่งเว็บ hardcode 'All Items' ให้ CPI_WCA อยู่แล้ว)
    if (dataset_id == "CPI_WCA") lbls <- lbls[names(lbls) == "TYPE_OF_TRANSFORMATION"]
    lbls <- lbls[order(names(lbls))]
    paste(p$country, paste(names(lbls), lbls, sep = ":", collapse = "|"), sep = "||")
  }
  groups <- split(parsed, map_chr(parsed, key_of))
  dup_groups <- groups[lengths(groups) > 1]

  # guard: ถ้ากลุ่มไหนมี freq (ที่ไม่ว่างเปล่า) มากกว่า 1 ค่าจริงๆ (เช่น
  # M ปนกับ Q) แปลว่า country+label เจาะจงไม่พอ ไม่ใช่ series เดียวกันจริง
  # — แยกออกจาก dup_groups ไปก่อน กันไม่ให้ splice ผิด
  freq_conflict <- map_lgl(dup_groups, function(g) {
    fr <- unique(vapply(map_chr(g, "freq"), normalize_freq, character(1)))
    fr <- fr[fr != ""]
    length(fr) > 1
  })
  if (any(freq_conflict)) {
    message(sprintf("  ⊘ ข้าม %d กลุ่มที่ freq ไม่ตรงกันจริง (เช่น M ปน Q) — ไม่ใช่ series เดียวกัน", sum(freq_conflict)))
  }
  dup_groups <- dup_groups[!freq_conflict]
  message(sprintf("  duplicate-label groups: %d", length(dup_groups)))

  for (g in dup_groups) {
    # winner: max(date ล่าสุด) ก่อน, ถ้าเท่ากันเลือกตัวที่ updated (Firestore
    # push timestamp) ใหม่กว่า — สะท้อนว่า pipeline ไหนยังแตะ doc นี้อยู่
    # จริง (เจอจริง 2026-09-04: CPI_WCA doc_id สั้น "INDEX" กลับเป็นตัว
    # backfill เก่าที่หยุดอัปเดตแล้ว ส่วน "CPI_T_IX" ยาวกว่าคือตัว live ที่
    # ยังได้รับข้อมูลต่อเนื่อง — สลับกับ pattern ของ CPI/CTOT/ฯลฯ เป๊ะ ใช้
    # ความยาว doc_id เทียบไม่ได้ทุก dataset) ถ้า updated เท่ากันอีก (ทั้งคู่
    # ไม่เคยถูกแตะหลัง push ครั้งแรกเลย) ค่อย fallback ไป doc_id สั้นกว่า
    # กัน error/สุ่ม
    stats <- map(g, function(p) list(
      id = p$id, name = p$name, max_date = if (nrow(p$points)) max(p$points$date) else "",
      updated = p$updated %||% "", len = nchar(p$id), points = p$points
    ))
    ord <- order(vapply(stats, \(s) s$max_date, character(1)), decreasing = TRUE)
    stats <- stats[ord]
    top_date <- stats[[1]]$max_date
    tied <- Filter(\(s) s$max_date == top_date, stats)
    if (length(tied) > 1) {
      tied <- tied[order(vapply(tied, \(s) s$updated, character(1)), decreasing = TRUE)]
      top_updated <- tied[[1]]$updated
      tied2 <- Filter(\(s) s$updated == top_updated, tied)
      if (length(tied2) > 1) tied <- tied2[order(vapply(tied2, \(s) s$len, integer(1)))]
      rest <- Filter(\(s) s$max_date != top_date, stats)
      stats <- c(tied, rest)
    }
    winner <- stats[[1]]
    losers <- stats[-1]

    for (loser in losers) {
      # sanity: ค่าที่ overlap ต้องตรงกัน (กันเคส mismatch ที่ยังไม่ verify
      # หลุดมาเผลอ splice ผิด) — ยอม tolerance 0.1% กัน floating point/revision เล็กน้อย
      common <- inner_join(winner$points, loser$points, by = "date", suffix = c(".w", ".l"))
      if (nrow(common) > 0) {
        rel_diff <- abs(common$value.w - common$value.l) / pmax(abs(common$value.w), abs(common$value.l), 1e-9)
        if (any(rel_diff > 0.001)) {
          message(sprintf("  ⊘ SKIP (ค่าไม่ตรงกัน ยังไม่ verify): %s <-> %s", winner$id, loser$id))
          total_skipped_mismatch <- total_skipped_mismatch + 1
          next
        }
      }

      # splice_ok = "ปลอดภัยที่จะลบตัวแพ้" — true โดย default (ไม่มีอะไรต้อง
      # เติมเลยก็ปลอดภัย) เป็น false ก็ต่อเมื่อพยายาม push จุดเติมแล้ว
      # "ไม่สำเร็จจริง" เท่านั้น (กัน data loss ถาวร — เจอจริง 2026-08-28:
      # รอบก่อนหน้า push ไม่สำเร็จเงียบๆ ~4000 คู่ (rate limit) ถ้าลบตัวแพ้
      # ไปโดยไม่เช็คตรงนี้ก่อน จะเสียประวัติเก่าที่ยังไม่ทันถูกเติมเข้า
      # ตัวชนะเลยถาวร)
      splice_ok <- TRUE
      fill <- imf_splice_fill_gaps(winner$points, loser$points)
      if (nrow(fill) > 0) {
        message(sprintf("  splice: %s <- %s (+%d จุดเก่า, %s ถึง %s)",
                         winner$id, loser$id, nrow(fill), min(fill$date), max(fill$date)))
        if (!DRY_RUN) {
          # ใช้ name เดิมของตัวชนะ (ไม่ใช่ doc_id) กัน field "name"
          # (ชื่ออ่านง่ายสำหรับแสดงผล) โดนทับด้วย doc_id เงียบๆ
          ok <- with_retry(push_series, token, winner$id, name = winner$name %||% winner$id, df = fill,
                            is_incremental = TRUE, meta = NULL, quiet = TRUE)
          splice_ok <- ok
          if (ok) total_spliced <- total_spliced + 1
          else message(sprintf("  ✗ splice push ไม่สำเร็จ — จะไม่ลบตัวแพ้ตัวนี้: %s", loser$id))
        } else {
          total_spliced <- total_spliced + 1
        }
      } else {
        message(sprintf("  (ไม่มีจุดต้องเติม): %s <- %s", winner$id, loser$id))
      }

      if (DELETE_LOSERS && splice_ok) {
        if (!DRY_RUN) {
          if (with_retry(delete_doc, token, loser$id)) {
            message(sprintf("  ✗ ลบแล้ว: %s", loser$id))
            total_deleted <- total_deleted + 1
          }
        } else {
          message(sprintf("  (จะลบ ถ้าไม่ใช่ dry run): %s", loser$id))
          total_deleted <- total_deleted + 1
        }
      }
    }
  }
}

message("\n══ SUMMARY ══")
message(sprintf("spliced: %d, deleted: %d, skipped (mismatch guard): %d",
                 total_spliced, total_deleted, total_skipped_mismatch))
