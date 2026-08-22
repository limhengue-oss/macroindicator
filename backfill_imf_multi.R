# ══════════════════════════════════════════════════════════════════
#  backfill_imf_multi.R
#  One-time historical backfill สำหรับ 21 IMF dataset (raw index/level,
#  ทุกประเทศ) — อ่านจาก scratch_imf/cleaned/<ID>_clean.csv ที่เตรียมไว้แล้ว
#  (long form, ตัด constant metadata column ออกแล้ว) → กรอง %change ออก →
#  splice CPI → build doc_id/meta/data → push แบบ is_incremental=FALSE
#
#  ดูที่มาการตัดสินใจทั้งหมดที่ scratch_imf/DESIGN.md และ
#  scratch_imf/TODO_cleaning.md (Audit 1-4)
#
#  รันจาก LOCAL เท่านั้น (ไม่มี GitHub Actions workflow คู่กัน — เป็น
#  one-time operation ตามแพทเทิร์นเดียวกับ backfill_imf_cpi_historical.R)
#
#  Environment variables:
#    GCP_SA_KEY — service account JSON — ไม่ใส่ก็รันได้แต่เป็น DRY RUN
#
#  รัน: Rscript backfill_imf_multi.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(readr); library(tibble)
  library(jsonlite); library(stringr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN <- sa_json == ""
if (DRY_RUN) message("── GCP_SA_KEY not set — running in DRY RUN mode (no Firestore push)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

suppressPackageStartupMessages({ library(httr2); library(jose) })
source("R/firestore.R")
source("R/imf_core.R")

country_map <- read_csv("data/imf_country_codes.csv", show_col_types = FALSE)
config <- read_csv("data/imf_dataset_config.csv", show_col_types = FALSE)

DATASET_IDS <- c(
  "CPI", "CPI_WCA", "CTOT", "EER", "ER", "IL", "ITG",
  "MFS_CBS", "MFS_FC", "MFS_FMP", "MFS_IR", "MFS_MA", "MFS_ODC", "MFS_OFC",
  "PCPS", "PI", "PI_WCA", "PPI", "QGDP_WCA", "QNEA"
)
# หมายเหตุ 2026-08-16: ตัด FSIC ออกจาก scope แล้ว (user ตัดสินใจ) — ซับซ้อน
# เกินไป (398 indicator, 11 sector) เทียบกับประโยชน์ที่ได้ ตอนนี้เหลือ 20 dataset

# รองรับ push แบบแบ่ง batch — ตั้ง IMF_BACKFILL_DATASETS="CPI,CPI_WCA,..."
# (comma-separated) เพื่อรันแค่บาง dataset ใน DATASET_IDS ข้างบน โดยไม่ต้อง
# แก้ไฟล์นี้แล้วต้องจำ revert — เว้นว่างไว้ = รันครบทุก dataset (ค่า default)
subset_env <- Sys.getenv("IMF_BACKFILL_DATASETS")
if (nzchar(subset_env)) {
  requested <- trimws(strsplit(subset_env, ",")[[1]])
  DATASET_IDS <- intersect(DATASET_IDS, requested)
  message(sprintf("── IMF_BACKFILL_DATASETS set — จำกัดเหลือ %d dataset: %s",
                   length(DATASET_IDS), paste(DATASET_IDS, collapse = ", ")))
}

token <- NULL
token_time <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  token_time <- Sys.time()
  message("  ✓ token acquired")
}

# manifest: doc_id ทุกตัวที่ push สำเร็จรอบนี้ (schema ใหม่) — ใช้โดย
# scripts/oneoff/cleanup_old_imf_docs.R เป็นตัวตัดสินว่า doc เก่า (schema
# เดิม) ตัวไหนเป็น "orphan" ที่ลบทิ้งได้ปลอดภัย (เขียนทันทีที่ push สำเร็จ
# ไม่ใช่ตอนจบ script — กัน manifest หายถ้า process ถูก interrupt กลางทาง)
dir.create("scratch_imf/test_results", showWarnings = FALSE, recursive = TRUE)
manifest_con <- if (!DRY_RUN) file("scratch_imf/test_results/backfill_doc_ids.txt", open = "a") else NULL

log_rows <- list()

for (dataset_id in DATASET_IDS) {
  # JWT token หมดอายุ 1 ชม. (ดู get_access_token ใน R/firestore.R) — batch
  # ที่มีหลาย dataset รวมกันอาจรันนานเกิน 1 ชม. ได้ (เจอจริงตอน push batch 1:
  # QNEA เป็น dataset สุดท้าย token หมดอายุพอดีระหว่างรัน push ล้มเหลวทั้ง
  # 3,537 series) — refresh token ใหม่ทุกครั้งที่ขึ้น dataset ใหม่ถ้าเก่ากว่า
  # 45 นาทีแล้ว (เผื่อ margin ก่อนหมดอายุจริงที่ 60 นาที) — ตัดสินใจ 2026-08-16
  if (!DRY_RUN && !is.null(token_time) && difftime(Sys.time(), token_time, units = "mins") > 45) {
    message("── Token ใกล้หมดอายุ (>45 นาที) — ขอ token ใหม่...")
    token <- get_access_token(sa)
    token_time <- Sys.time()
    message("  ✓ token refreshed")
  }
  message(sprintf("\n══ %s ══", dataset_id))
  csv_path <- sprintf("scratch_imf/cleaned/%s_clean.csv", dataset_id)
  if (!file.exists(csv_path)) {
    message(sprintf("  ⊘ SKIP: %s not found", csv_path))
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "skip_no_file", n_series = 0, n_obs = 0)
    next
  }

  cfg_row <- config %>% filter(.data$dataset_id == !!dataset_id)
  version <- cfg_row$version[1]
  category_label <- cfg_row$category_label[1]
  dataset_dims <- strsplit(cfg_row$dimension_order[1], ",")[[1]]
  non_country_dims <- setdiff(dataset_dims, "COUNTRY")
  dim_roles <- imf_parse_dimension_roles(cfg_row$dimension_order[1], cfg_row$dimension_roles[1])

  df <- read_csv(csv_path, show_col_types = FALSE, guess_max = 100000)

  # 1) กรอง %change ออก (Audit 1) — generic ทุก dataset
  n_before <- nrow(df)
  df <- imf_drop_pct_change_rows(df)
  n_after_pct <- nrow(df)

  # 2) splice เฉพาะ CPI (Audit 2) + เก็บแค่ความถี่ละเอียดสุดต่อ series
  # (Monthly ถ้ามี ไม่งั้น Quarterly, ไม่งั้น Annual — ตัดสินใจ 2026-08-16)
  if (dataset_id == "CPI") {
    df <- imf_splice_cpi(df)
    df <- imf_cpi_drop_raw_weight(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDEX_TYPE", "COICOP_1999", "TYPE_OF_TRANSFORMATION"))
  }
  # PPI: เก็บทั้ง PPI และ WPI แยก 2 series ตามเดิม (dual-measurement เหมือน
  # CPI/HICP — ไม่บังคับเลือก) แค่เอาความถี่ละเอียดสุดต่อ (ประเทศ, ประเภท)
  if (dataset_id == "PPI") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
  }
  # PI: เก็บ Index/SA-Index (S_ADJUSTMENT ซ้ำข้อมูลกับ TYPE_OF_TRANSFORMATION
  # อยู่แล้ว ไม่บังคับเลือก) แยก 7 หมวดอุตสาหกรรมตามเดิม แค่เอาความถี่
  # ละเอียดสุดต่อ (ประเทศ, หมวด, Index/SA) — ตัดสินใจ 2026-08-16
  if (dataset_id == "PI") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "PRODUCTION_INDEX", "TYPE_OF_TRANSFORMATION"))
  }
  # ITG: เก็บ FOB/CIF ของ "Imports of goods" แยก 2 series ตามเดิม
  # (dual-measurement, คำนวณจากกันไม่ได้ตรงๆ) ใส่ VALUATION เข้า key ด้วย
  # กันปนกันตอนเลือกความถี่ละเอียดสุด (Track 1/bulk CSV มี VALUATION แยก
  # column ตรงๆ — Track 2/live API ไม่มี column นี้เลย แต่ฝัง FOB/CIF ไว้ใน
  # TYPE_OF_TRANSFORMATION แทน เช่น "CIF_USD"/"FOB_USD" — ใส่ทั้งคู่ไว้ใน
  # key เผื่อไว้ ตัวไหนไม่มีจริงจะถูกตัดออกอัตโนมัติโดย imf_finest_freq_only)
  # ตัดสินใจ 2026-08-16
  if (dataset_id == "ITG") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "VALUATION", "TYPE_OF_TRANSFORMATION"))
  }
  # PCPS: ตัด Index ที่ซ้ำกับ US dollars ทิ้ง (เก็บ 28 composite index ที่
  # ไม่มี USD คู่กันไว้เหมือนเดิม) + เอาความถี่ละเอียดสุดต่อสินค้า
  if (dataset_id == "PCPS") {
    df <- imf_pcps_drop_redundant_index(df)
    df <- imf_finest_freq_only(df, c("INDICATOR", "DATA_TRANSFORMATION"))
  }
  # EER: 4 indicator ต่างกันจริง (NEER/REER x วิธีถ่วงน้ำหนัก) เก็บไว้ครบ
  # แค่เอาความถี่ละเอียดสุดต่อ (ประเทศ, indicator) — ตัดสินใจ 2026-08-16
  if (dataset_id == "EER") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
  }
  # IL: ตัด SDR ที่ derivable จาก USD ทิ้ง (เก็บ indicator ที่มีแค่ SDR
  # อย่างเดียวไว้ เช่น Gold reserves at 35 SDRs per ounce) + finest-freq
  if (dataset_id == "IL") {
    df <- imf_il_prefer_usd(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
  }
  # MFS_CBS: ตัด "Net" row ที่คำนวณคืนได้จาก Assets-Liabilities ทิ้ง +
  # finest-freq (เก็บ Euro area wide residency และสกุลเงินไว้ตามเดิม —
  # ซับซ้อนกว่า ยังไม่แตะ) — ตัดสินใจ 2026-08-16
  if (dataset_id == "MFS_CBS") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
  }
  # MFS_FC/MFS_ODC/MFS_OFC: งบดุลเหมือน MFS_CBS — ตัด "Net" row (verify
  # สูตรซ้ำแล้วกับ MFS_ODC: diff ≈ 0) + finest-freq (คอลัมน์สกุลเงินคนละชื่อ
  # กันต่อ dataset: MFS_FC ใช้ UNIT, MFS_ODC/OFC ใช้ TYPE_OF_TRANSFORMATION)
  # MFS_FMP/MFS_IR/MFS_MA: ไม่ใช่งบดุล ไม่มี Net row แค่ finest-freq พอ —
  # ตัดสินใจ 2026-08-16
  if (dataset_id == "MFS_FC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
  }
  if (dataset_id == "MFS_ODC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
  }
  if (dataset_id == "MFS_OFC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
  }
  if (dataset_id == "MFS_FMP") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
  }
  if (dataset_id == "MFS_IR") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
  }
  if (dataset_id == "MFS_MA") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
  }
  # QNEA: เก็บเฉพาะ 18 indicator ที่เป็นองค์ประกอบหลักของ GDP (ตัดรายละเอียด
  # ย่อย 9 ตัวที่ประเทศรายงานน้อยอยู่แล้ว — ตัดเพื่อลดความสับสน) —
  # ตัดสินใจร่วมกับ user 2026-08-16
  if (dataset_id == "QNEA") {
    df <- imf_qnea_gdp_components_only(df)
  }
  # 2b) ER: ตัดคู่สกุลเงินอื่นออก เหลือแค่เทียบ USD (คำนวณคู่อื่นคืนได้เอง
  # ด้วย cross-rate ถ้ามี USD ของทุกประเทศ — ตัดสินใจ 2026-08-16)
  if (dataset_id == "ER") {
    df <- imf_filter_er_usd_only(df)
  }
  n_after_splice <- nrow(df)

  message(sprintf("  rows: %d -> (drop pct-change) %d -> (splice) %d", n_before, n_after_pct, n_after_splice))

  # dataset ที่ไม่มี COUNTRY เลย (เช่น PCPS = world commodity prices, ไม่แยก
  # ประเทศ) — ใส่ pseudo-country "WLD" ตรงๆ (ไม่ผ่าน fallback SERIES_CODE
  # เพราะ token แรกของ SERIES_CODE ใน PCPS คือรหัสสินค้า ไม่ใช่รหัสประเทศ/
  # ภูมิภาค จะเอามาใช้แทน iso3 ตรงๆไม่ได้ความหมาย) ยังคง push ได้ปกติ ไม่ skip ทิ้ง
  no_country_dataset <- !"COUNTRY" %in% names(df)
  if (no_country_dataset) {
    df$COUNTRY <- "World (no country dimension)"
    df$iso3 <- "WLD"
    message("  (no COUNTRY column — treating as single global 'WLD' pseudo-country)")
  }

  # 3) join ISO3 — LEFT join แล้ว fallback เป็นรหัสจาก SERIES_CODE (token
  # แรกก่อน ".") สำหรับแถวที่ COUNTRY ไม่ใช่ประเทศจริง (dataset _WCA/
  # aggregate ใช้ชื่อภูมิภาค/กลุ่ม เช่น "World", "Oceania" ซึ่งไม่มีใน
  # ISO3 codelist — แต่ SERIES_CODE ยังมีรหัสกลุ่ม เช่น "U009", "G001" ให้ใช้แทนได้)
  # ข้าม join ทั้งหมดถ้าเป็น no_country_dataset (ตั้ง iso3="WLD" ไว้แล้วข้างบน)
  if (!no_country_dataset) {
    df <- df %>% left_join(country_map, by = c("COUNTRY" = "imf_name"))
    n_unmatched <- sum(is.na(df$iso3))
    if (n_unmatched > 0 && "SERIES_CODE" %in% names(df)) {
      fallback_code <- str_extract(df$SERIES_CODE, "^[^.]+")
      df$iso3 <- ifelse(is.na(df$iso3), fallback_code, df$iso3)
    }
  } else {
    n_unmatched <- 0
  }
  n_after_iso <- sum(!is.na(df$iso3))
  df <- df %>% filter(!is.na(iso3))
  message(sprintf("  rows with matched/fallback code: %d (%d used ISO3 country map, %d used SERIES_CODE fallback for regions/aggregates)",
                   n_after_iso, n_after_iso - n_unmatched, min(n_unmatched, n_after_iso)))

  if (nrow(df) == 0) {
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "empty_after_filter", n_series = 0, n_obs = 0)
    next
  }

  # 4) build doc_id per row (schema 2026-08-22: derive-forward จาก dims ที่
  # role เป็น component/variant เท่านั้น แทนการต่อ SERIES_CODE ดิบทั้งก้อน
  # แบบเดิม — ใช้ column ตามชื่อ dimension จริง (INDICATOR/COICOP_1999/ฯลฯ)
  # เพราะ bulk CSV เก็บ text อ่านง่ายในคอลัมน์เหล่านี้อยู่แล้ว ไม่ต้องพึ่ง
  # SERIES_CODE ที่เป็นแค่รหัสต่อกันด้วย "." ซึ่งไม่มีความหมายแยกเป็นชิ้นๆ)
  available_dims <- intersect(non_country_dims, names(df))
  df$doc_id <- pmap_chr(df[c("iso3", available_dims)], function(...) {
    row <- list(...)
    row_dims <- imf_build_dims(row[available_dims], dim_roles)
    imf_build_doc_id(dataset_id, row$iso3, row_dims)
  })
  df$date <- imf_period_to_date(df$TIME_PERIOD)
  df <- df %>% filter(!is.na(date), is.finite(OBS_VALUE))

  # meta text columns available (varies per dataset) for currency detection + fullName
  # (INDEX_TYPE/COICOP_1999 ใช้เฉพาะ CPI สำหรับสร้างชื่อ+recommended flag)
  # ต้องรวม non_country_dims ทั้งหมดด้วย ไม่งั้น series_keys จะขาด column ที่
  # ต้องใช้สร้าง dims/meta ต่อ series ในลูปข้างล่าง (เจอปัญหาเดียวกับ
  # fetch_imf_multi.R — WGT_TYPE/DATA_TRANSFORMATION/PRODUCTION_INDEX/
  # PRICE_TYPE/S_ADJUSTMENT จะหายไปถ้าไม่รวมเข้ามา)
  text_cols <- union(
    c("INDICATOR", "TYPE_OF_TRANSFORMATION", "UNIT", "TRANSFORMATION",
      "SERIES_NAME", "FREQUENCY", "INDEX_TYPE", "COICOP_1999"),
    available_dims
  )
  text_cols <- intersect(text_cols, names(df))

  series_keys <- df %>% distinct(doc_id, iso3, .keep_all = TRUE) %>% select(doc_id, iso3, all_of(text_cols))
  df_split <- split(df %>% select(doc_id, date, OBS_VALUE), df$doc_id)

  ok_count <- 0
  n_series <- nrow(series_keys)
  message(sprintf("  pushing %d series%s...", n_series, if (DRY_RUN) " (dry run)" else ""))

  for (i in seq_len(n_series)) {
    row <- series_keys[i, ]
    pts <- df_split[[row$doc_id]] %>% distinct(date, .keep_all = TRUE) %>%
      arrange(date) %>% transmute(date, value = OBS_VALUE)
    if (nrow(pts) == 0) next

    freq_val <- if ("FREQUENCY" %in% names(row)) row$FREQUENCY[[1]] else ""
    currency_val <- imf_detect_currency(unlist(row[text_cols]))
    unit_val <- if ("UNIT" %in% names(row)) row$UNIT[[1]] else ""

    if (dataset_id == "CPI") {
      # CPI ไม่มี INDICATOR/SERIES_NAME text column เลย (ต่างจาก dataset
      # อื่น) — ชื่อทั่วไปจะกลายเป็นแค่ "CPI" เฉยๆ ไม่บอกหมวด/ประเภท เลย
      # สร้างชื่อเฉพาะจาก COICOP_1999 (หมวด) + TYPE_OF_TRANSFORMATION
      # (Index/Weight) + INDEX_TYPE แบบย่อ (CPI/HICP) แทน
      cpi_idx_short <- imf_cpi_index_type_short(row$INDEX_TYPE[[1]])
      full_name <- sprintf("%s — %s (%s)", row$COICOP_1999[[1]], row$TYPE_OF_TRANSFORMATION[[1]], cpi_idx_short)
    } else {
      fullname_parts <- na.omit(unlist(row[intersect(c("INDICATOR", "SERIES_NAME"), names(row))]))
      full_name <- if (length(fullname_parts) > 0) paste(unique(fullname_parts), collapse = " — ") else dataset_id
    }

    row_dims <- imf_build_dims(as.list(row[intersect(available_dims, names(row))]), dim_roles)

    meta <- list(
      fullName = sprintf("%s (%s)", full_name, row$iso3),
      currency = if (is.null(currency_val)) "" else currency_val,
      unit = if (is.null(unit_val) || is.na(unit_val)) "" else unit_val,
      freq = if (is.null(freq_val) || is.na(freq_val)) "" else freq_val,
      source = sprintf("IMF STA %s %s", dataset_id, version),
      country = list(code = row$iso3, label = imf_country_name(row$iso3)),
      category = list(code = dataset_id, label = category_label),
      dims = row_dims
    )
    if (dataset_id == "CPI") {
      rec_type <- imf_cpi_recommended_type(row$iso3)
      meta$recommendedIndexType <- rec_type
      meta$isRecommended <- identical(cpi_idx_short, rec_type)
    }

    if (DRY_RUN) {
      ok_count <- ok_count + 1
      if (i <= 3 || i == n_series) {
        message(sprintf("    [%d/%d] %s: %d pts, latest %s=%s", i, n_series, row$doc_id,
                         nrow(pts), tail(pts$date, 1), tail(pts$value, 1)))
      }
    } else {
      if (push_series(token, row$doc_id, meta$fullName, pts, is_incremental = FALSE, meta = meta, quiet = TRUE)) {
        ok_count <- ok_count + 1
        writeLines(row$doc_id, manifest_con)
      }
      if (i %% 200 == 0) message(sprintf("    ... %d/%d pushed", i, n_series))
    }
  }

  message(sprintf("  ✓ %s: %d/%d series ok, %d total obs", dataset_id, ok_count, n_series, nrow(df)))
  log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "ok",
                                              n_series = ok_count, n_obs = nrow(df))
}

if (!DRY_RUN) close(manifest_con)

log_df <- bind_rows(log_rows)
write_csv(log_df, "scratch_imf/test_results/backfill_log.csv")
message("\n══ SUMMARY ══")
print(log_df)
message(sprintf("\n✓ Done. Total series: %d, total obs: %d", sum(log_df$n_series), sum(log_df$n_obs)))
