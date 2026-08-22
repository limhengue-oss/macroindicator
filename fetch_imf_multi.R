# ══════════════════════════════════════════════════════════════════
#  fetch_imf_multi.R
#  Track 2 — อัพเดทข้อมูล IMF STA 21 dataset ต่อเนื่องไปข้างหน้า (รวมทุก
#  dataset ไว้ไฟล์เดียว, 1 provider = IMF) ผ่าน SDMX API wildcard, ทุกประเทศ,
#  rolling window ~2 ปีย้อนหลัง กัน revision ตกหล่น — raw index/level ดิบ
#  ที่สุด (กรอง %change ออก, splice ถ้าเป็น CPI)
#
#  ที่มาการตัดสินใจทั้งหมด: scratch_imf/DESIGN.md, scratch_imf/TODO_cleaning.md
#
#  หมายเหตุ: ไฟล์นี้ไม่เกี่ยวกับ fetch_imf_cpi.R (curated CPI by-country x
#  COICOP category ที่หน้าเว็บ index.html หน้า GlobalCPI อ้างอิง doc_id
#  ตรงๆ — ห้ามลบ/แก้) ส่วน fetch_imf.R เดิม (GDP/FSIC/CPI_WCA curated subset)
#  ถูกลบไปแล้ว 2026-08-16 หลังยืนยันว่าไม่เคย push ข้อมูลจริงขึ้น Firestore
#  เลยสักครั้ง (workflow เดิมรันแบบ dry_run=true มาตลอด) จึงไม่มีผลกระทบต่อ
#  หน้าเว็บ — backup เก็บไว้ที่ scratch_imf/backup_fetch_scripts/fetch_imf_legacy_pre_merge.R
#
#  Environment variables:
#    GCP_SA_KEY  — service account JSON — ไม่ใส่ก็รันได้แต่เป็น DRY RUN
#
#  รัน local:  Rscript fetch_imf_multi.R
#  รัน CI:     GitHub Actions inject env vars จาก Secrets (.github/workflows/fetch-imf.yml)
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(readr); library(tibble)
  library(jsonlite); library(stringr)
  library(httr2); library(jose); library(xml2)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "series"

sa_json <- Sys.getenv("GCP_SA_KEY")
DRY_RUN  <- sa_json == ""
if (DRY_RUN) message("── GCP_SA_KEY not set — running in DRY RUN mode (no Firestore push)")
sa <- if (DRY_RUN) NULL else fromJSON(sa_json)

source("R/firestore.R")
source("R/imf_core.R")

config <- read_csv("data/imf_dataset_config.csv", show_col_types = FALSE)
START_PERIOD <- format(Sys.Date() - 730, "%Y-%m")  # rolling ~2 year window

token <- NULL
token_time <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  token_time <- Sys.time()
  message("  ✓ token acquired")
}

log_rows <- list()

for (i in seq_len(nrow(config))) {
  # JWT token หมดอายุ 1 ชม. — refresh ทุกครั้งที่ขึ้น dataset ใหม่ถ้าเก่า
  # กว่า 45 นาที (เจอบั๊กจริงตอน backfill batch 1 — QNEA เป็น dataset
  # สุดท้าย token หมดอายุพอดีระหว่างรัน) — ตัดสินใจ 2026-08-16
  if (!DRY_RUN && !is.null(token_time) && difftime(Sys.time(), token_time, units = "mins") > 45) {
    message("── Token ใกล้หมดอายุ (>45 นาที) — ขอ token ใหม่...")
    token <- get_access_token(sa)
    token_time <- Sys.time()
    message("  ✓ token refreshed")
  }
  cfg <- config[i, ]
  dataset_id <- cfg$dataset_id
  agency     <- cfg$agency
  version    <- cfg$version
  dims       <- strsplit(cfg$dimension_order, ",")[[1]]
  n_dims     <- length(dims)

  message(sprintf("\n══ %s ══", dataset_id))
  df <- imf_fetch_wildcard(agency, dataset_id, version, n_dims, START_PERIOD)
  message(sprintf("  raw fetch: %d rows", nrow(df)))

  if (nrow(df) == 0) {
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "no_data", n_series = 0, n_obs = 0)
    next
  }

  df <- imf_drop_pct_change_rows(df)
  message(sprintf("  after %%change filter: %d rows", nrow(df)))

  if (dataset_id == "CPI") {
    df <- imf_splice_cpi(df)
    df <- imf_cpi_drop_raw_weight(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDEX_TYPE", "COICOP_1999", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after splice + drop-raw-weight + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "PPI") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "PI") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "PRODUCTION_INDEX", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "ITG") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "VALUATION", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "PCPS") {
    df <- imf_pcps_drop_redundant_index(df)
    df <- imf_finest_freq_only(df, c("INDICATOR", "DATA_TRANSFORMATION"))
    message(sprintf("  after drop-redundant-index + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "EER") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "IL") {
    df <- imf_il_prefer_usd(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
    message(sprintf("  after prefer-usd + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_CBS") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after drop-net + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_FC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
    message(sprintf("  after drop-net + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_ODC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after drop-net + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_OFC") {
    df <- imf_drop_net_derived_rows(df)
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after drop-net + finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_FMP") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "TYPE_OF_TRANSFORMATION"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_IR") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "MFS_MA") {
    df <- imf_finest_freq_only(df, c("COUNTRY", "INDICATOR", "UNIT"))
    message(sprintf("  after finest-freq: %d rows", nrow(df)))
  }
  if (dataset_id == "QNEA") {
    df <- imf_qnea_gdp_components_only(df)
    message(sprintf("  after gdp-components-only: %d rows", nrow(df)))
  }
  if (dataset_id == "ER") {
    df <- imf_filter_er_usd_only(df)
    message(sprintf("  after ER USD-only filter: %d rows", nrow(df)))
  }

  if (!"COUNTRY" %in% names(df)) {
    message("  ⊘ no COUNTRY dimension in this dataset (world/aggregate-only) — nothing to push per-country")
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "no_country_dim", n_series = 0, n_obs = 0)
    next
  }

  # Live SDMX API responses ไม่มี field "SERIES_CODE" (มีแค่ใน bulk CSV
  # export ที่ใช้ backfill) — สร้าง synthetic series key เองจาก dimension
  # values จริง (ตาม dimension_order ใน config, ไม่รวม COUNTRY)
  non_country_dims <- setdiff(dims, "COUNTRY")
  missing_dims <- setdiff(non_country_dims, names(df))
  if (length(missing_dims) > 0) {
    message(sprintf("  ⊘ missing expected dimension column(s): %s — skip", paste(missing_dims, collapse = ", ")))
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "missing_dims", n_series = 0, n_obs = 0)
    next
  }
  df$series_suffix <- do.call(paste, c(df[non_country_dims], sep = "."))
  df$doc_id <- map2_chr(df$COUNTRY, df$series_suffix, ~imf_build_doc_id(dataset_id, .x, .y))
  df$date <- imf_period_to_date(df$TIME_PERIOD)
  df <- df %>% filter(!is.na(date), is.finite(OBS_VALUE))

  text_cols <- intersect(c("INDICATOR", "TYPE_OF_TRANSFORMATION", "UNIT", "TRANSFORMATION",
                            "SERIES_NAME", "FREQUENCY", "INDEX_TYPE", "COICOP_1999"), names(df))
  series_keys <- df %>% distinct(doc_id, COUNTRY, .keep_all = TRUE) %>% select(doc_id, COUNTRY, all_of(text_cols))
  df_split <- split(df %>% select(doc_id, date, OBS_VALUE), df$doc_id)

  ok_count <- 0
  n_series <- nrow(series_keys)
  message(sprintf("  pushing %d series%s...", n_series, if (DRY_RUN) " (dry run)" else ""))

  for (j in seq_len(n_series)) {
    row <- series_keys[j, ]
    pts <- df_split[[row$doc_id]] %>% distinct(date, .keep_all = TRUE) %>%
      arrange(date) %>% transmute(date, value = OBS_VALUE)
    if (nrow(pts) == 0) next

    freq_val <- if ("FREQUENCY" %in% names(row)) row$FREQUENCY[[1]] else ""
    currency_val <- imf_detect_currency(unlist(row[text_cols]))
    unit_val <- if ("UNIT" %in% names(row)) row$UNIT[[1]] else ""

    if (dataset_id == "CPI") {
      cpi_idx_short <- imf_cpi_index_type_short(row$INDEX_TYPE[[1]])
      full_name <- sprintf("%s — %s (%s)", row$COICOP_1999[[1]], row$TYPE_OF_TRANSFORMATION[[1]], cpi_idx_short)
    } else {
      fullname_parts <- na.omit(unlist(row[intersect(c("INDICATOR", "SERIES_NAME"), names(row))]))
      full_name <- if (length(fullname_parts) > 0) paste(unique(fullname_parts), collapse = " — ") else dataset_id
    }

    meta <- list(
      fullName = sprintf("%s (%s)", full_name, row$COUNTRY),
      currency = if (is.null(currency_val)) "" else currency_val,
      unit = if (is.null(unit_val) || is.na(unit_val)) "" else unit_val,
      freq = if (is.null(freq_val) || is.na(freq_val)) "" else freq_val,
      source = sprintf("IMF STA %s %s", dataset_id, version)
    )
    if (dataset_id == "CPI") {
      rec_type <- imf_cpi_recommended_type(row$COUNTRY)
      meta$recommendedIndexType <- rec_type
      meta$isRecommended <- identical(cpi_idx_short, rec_type)
    }

    if (DRY_RUN) {
      ok_count <- ok_count + 1
      if (j <= 3 || j == n_series) {
        message(sprintf("    [%d/%d] %s: %d pts, latest %s=%s", j, n_series, row$doc_id,
                         nrow(pts), tail(pts$date, 1), tail(pts$value, 1)))
      }
    } else {
      if (push_series(token, row$doc_id, meta$fullName, pts, is_incremental = TRUE, meta = meta, quiet = TRUE)) {
        ok_count <- ok_count + 1
      }
      if (j %% 200 == 0) message(sprintf("    ... %d/%d pushed", j, n_series))
    }
  }

  message(sprintf("  ✓ %s: %d/%d series ok, %d total obs", dataset_id, ok_count, n_series, nrow(df)))
  log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "ok",
                                              n_series = ok_count, n_obs = nrow(df))
}

log_df <- bind_rows(log_rows)
dir.create("scratch_imf/test_results", showWarnings = FALSE, recursive = TRUE)
write_csv(log_df, "scratch_imf/test_results/fetch_multi_log.csv")
message("\n══ SUMMARY ══")
print(log_df)
message(sprintf("\n✓ Done. Total series: %d, total obs: %d", sum(log_df$n_series), sum(log_df$n_obs)))
