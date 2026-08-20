# ══════════════════════════════════════════════════════════════════
#  download_imf_multi_raw.R
#  โหลด raw data ของแต่ละ dataset ใน data/imf_dataset_config.csv จาก IMF
#  SDMX API เก็บลง local (workfile/raw_imf/{dataset_id}.rds) — ไม่ push
#  Firestore เลย ใช้สำหรับตรวจสอบ/ทดลอง cleaning offline โดยไม่ต้องยิง
#  API ซ้ำทุกครั้ง (ตัดปัญหา rate limit + เวลาที่เสียไปกับ network)
#
#  รัน local: Rscript download_imf_multi_raw.R
#  รันดึงเฉพาะบาง dataset: Rscript download_imf_multi_raw.R CPI,FSIC
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(readr); library(tibble)
  library(httr2); library(xml2)
})

source("R/imf_core.R")

OUT_DIR <- "workfile/raw_imf"
dir.create(OUT_DIR, showWarnings = FALSE, recursive = TRUE)

config <- read_csv("data/imf_dataset_config.csv", show_col_types = FALSE)
START_PERIOD <- format(Sys.Date() - 730, "%Y-%m")  # rolling ~2 year window เหมือน fetch_imf_multi.R

args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 0) {
  wanted <- strsplit(args[1], ",")[[1]]
  config <- config %>% filter(dataset_id %in% wanted)
  if (nrow(config) == 0) stop("ไม่พบ dataset_id ที่ระบุใน data/imf_dataset_config.csv")
}

log_rows <- list()

for (i in seq_len(nrow(config))) {
  cfg <- config[i, ]
  dataset_id <- cfg$dataset_id
  agency     <- cfg$agency
  version    <- cfg$version
  n_dims     <- length(strsplit(cfg$dimension_order, ",")[[1]])

  out_path <- file.path(OUT_DIR, paste0(dataset_id, ".rds"))
  message(sprintf("\n══ %s ══", dataset_id))
  df <- imf_fetch_wildcard(agency, dataset_id, version, n_dims, START_PERIOD)
  message(sprintf("  raw fetch: %d rows", nrow(df)))

  saveRDS(df, out_path)
  message(sprintf("  ✓ saved -> %s", out_path))

  log_rows[[length(log_rows) + 1]] <- tibble(
    dataset_id = dataset_id, n_rows = nrow(df), file = out_path
  )
}

log_df <- bind_rows(log_rows)
message("\n══ SUMMARY ══")
print(log_df)
message(sprintf("\n✓ Done. ไฟล์ raw อยู่ที่ %s (โหลดกลับด้วย readRDS())", OUT_DIR))
