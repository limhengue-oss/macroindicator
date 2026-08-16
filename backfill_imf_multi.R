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
  "CPI", "CPI_WCA", "CTOT", "EER", "ER", "FSIC", "IL", "ITG",
  "MFS_CBS", "MFS_FC", "MFS_FMP", "MFS_IR", "MFS_MA", "MFS_ODC", "MFS_OFC",
  "PCPS", "PI", "PI_WCA", "PPI", "QGDP_WCA", "QNEA"
)

token <- NULL
if (!DRY_RUN) {
  message("── Authenticating with Firestore...")
  token <- get_access_token(sa)
  message("  ✓ token acquired")
}

log_rows <- list()

for (dataset_id in DATASET_IDS) {
  message(sprintf("\n══ %s ══", dataset_id))
  csv_path <- sprintf("scratch_imf/cleaned/%s_clean.csv", dataset_id)
  if (!file.exists(csv_path)) {
    message(sprintf("  ⊘ SKIP: %s not found", csv_path))
    log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "skip_no_file", n_series = 0, n_obs = 0)
    next
  }

  cfg_row <- config %>% filter(.data$dataset_id == !!dataset_id)
  version <- cfg_row$version[1]

  df <- read_csv(csv_path, show_col_types = FALSE, guess_max = 100000)

  # 1) กรอง %change ออก (Audit 1) — generic ทุก dataset
  n_before <- nrow(df)
  df <- imf_drop_pct_change_rows(df)
  n_after_pct <- nrow(df)

  # 2) splice เฉพาะ CPI (Audit 2)
  if (dataset_id == "CPI") {
    df <- imf_splice_cpi(df)
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

  # 4) build doc_id per row, then group into series
  df$doc_id <- map2_chr(df$iso3, df$SERIES_CODE, ~imf_build_doc_id(dataset_id, .x, .y))
  df$date <- imf_period_to_date(df$TIME_PERIOD)
  df <- df %>% filter(!is.na(date), is.finite(OBS_VALUE))

  # meta text columns available (varies per dataset) for currency detection + fullName
  text_cols <- intersect(c("INDICATOR", "TYPE_OF_TRANSFORMATION", "UNIT", "TRANSFORMATION",
                            "SERIES_NAME", "FREQUENCY"), names(df))

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

    fullname_parts <- na.omit(unlist(row[intersect(c("INDICATOR", "SERIES_NAME"), names(row))]))
    full_name <- if (length(fullname_parts) > 0) paste(unique(fullname_parts), collapse = " — ") else dataset_id
    freq_val <- if ("FREQUENCY" %in% names(row)) row$FREQUENCY[[1]] else ""
    currency_val <- imf_detect_currency(unlist(row[text_cols]))
    unit_val <- if ("UNIT" %in% names(row)) row$UNIT[[1]] else ""

    meta <- list(
      fullName = sprintf("%s (%s)", full_name, row$iso3),
      currency = if (is.null(currency_val)) "" else currency_val,
      unit = if (is.null(unit_val) || is.na(unit_val)) "" else unit_val,
      freq = if (is.null(freq_val) || is.na(freq_val)) "" else freq_val,
      source = sprintf("IMF STA %s %s", dataset_id, version)
    )

    if (DRY_RUN) {
      ok_count <- ok_count + 1
      if (i <= 3 || i == n_series) {
        message(sprintf("    [%d/%d] %s: %d pts, latest %s=%s", i, n_series, row$doc_id,
                         nrow(pts), tail(pts$date, 1), tail(pts$value, 1)))
      }
    } else {
      if (push_series(token, row$doc_id, meta$fullName, pts, is_incremental = FALSE, meta = meta, quiet = TRUE)) {
        ok_count <- ok_count + 1
      }
      if (i %% 200 == 0) message(sprintf("    ... %d/%d pushed", i, n_series))
    }
  }

  message(sprintf("  ✓ %s: %d/%d series ok, %d total obs", dataset_id, ok_count, n_series, nrow(df)))
  log_rows[[length(log_rows) + 1]] <- tibble(dataset_id = dataset_id, status = "ok",
                                              n_series = ok_count, n_obs = nrow(df))
}

log_df <- bind_rows(log_rows)
dir.create("scratch_imf/test_results", showWarnings = FALSE, recursive = TRUE)
write_csv(log_df, "scratch_imf/test_results/backfill_log.csv")
message("\n══ SUMMARY ══")
print(log_df)
message(sprintf("\n✓ Done. Total series: %d, total obs: %d", sum(log_df$n_series), sum(log_df$n_obs)))
