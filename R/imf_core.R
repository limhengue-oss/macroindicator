# ══════════════════════════════════════════════════════════════════
#  R/imf_core.R — shared helpers ใช้ร่วมกันทุก fetch_imf_<dataset>.R และ
#  backfill_imf_multi.R (21-dataset raw/index pipeline, ดู
#  scratch_imf/DESIGN.md สำหรับที่มาของการตัดสินใจทั้งหมด)
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(dplyr); library(purrr); library(stringr); library(tibble)
})

# ── %change filter — ใช้กับทุก dataset เหมือนกัน (Audit 1): ตัดแถวที่
# character column ไหนก็ตามมีค่าเป็น YoY/MoM/period-over-period percent
# change ทิ้ง ไม่ต้องระบุ column ต่อ dataset เพราะ pattern นี้เจาะจงพอ
# ที่จะไม่ false-positive กับ field อื่น (verify แล้วใน Audit 1)
# ครอบคลุมทั้ง 2 รูปแบบที่ IMF ใช้จริง: bulk CSV export เป็นข้อความเต็ม
# ("Year-over-year (YOY) percent change") ส่วน live SDMX API คืนเป็นโค้ด
# ย่อ ("YOY_PCH_PT", "POP_PCH_PT", "SA_POP_PCH_PT") — verify จาก PPI live
# response จริงระหว่าง implement (bug เจอจริง: โค้ดย่อหลุดผ่าน pattern เดิม)
# หมายเหตุ: ห้ามใช้ \b ล้อมรอบโค้ดที่ต่อ "_" ทั้งหน้า/หลัง (เช่น
# "CIF_POP_PCH_PT", "YOY_PCH_PT") เพราะ "_" นับเป็น word character ใน
# regex — \b ระหว่างตัวอักษรกับ "_" จะไม่ขึ้นเป็น boundary เลย ทั้งด้านหน้า
# และด้านหลัง (bug ที่เจอจริงตอนทดสอบ PPI แล้ว ITG live fetch — ตัวแรกพลาด
# เพราะ \b ปิดท้าย, ตัวสองพลาดเพราะ \b เปิดหน้าด้วย prefix แบบ "CIF_") —
# ใช้ plain substring match ไม่มี \b เลยสำหรับโค้ดกลุ่มนี้ — เจอโค้ดจริงจาก
# live API หลายรูปแบบที่ไม่ใช่แค่ YOY_PCH/POP_PCH เช่น MFS_CBS ใช้
# "PCH_CP_A_PT" (Percent Change, Corresponding Period) ซึ่งไม่มี YOY/POP/MOM
# นำหน้าเลย — สรุปว่า "PCH" (Percent CHange) เป็น token มาตรฐานของ IMF ที่
# ใช้แทน %change เสมอไม่ว่ารูปแบบไหน เลยจับแค่ "PCH" เป็น substring กว้างๆ
# (ตรวจสอบแล้วว่าไม่ชนกับโค้ดอื่นในทุก dataset ที่ audit มา)
IMF_PCT_CHANGE_PATTERN <- paste0(
  "(?i)year.?over.?year|period.?over.?period|percent change|",
  "\\bYOY\\b|\\bMOM\\b|PCH"
)

imf_drop_pct_change_rows <- function(df) {
  char_cols <- names(df)[sapply(df, is.character)]
  is_pct_row <- Reduce(`|`, lapply(char_cols, function(col) {
    grepl(IMF_PCT_CHANGE_PATTERN, df[[col]], perl = TRUE) & !is.na(df[[col]])
  }))
  df[!is_pct_row, ]
}

# ── CPI splice (Audit 2) — ratio-anchor: native Index ที่ขาดหาย เติมจาก
# Standard-Reference-Period Index โดยใช้ anchor (จุดที่มีทั้งคู่) ที่ใกล้
# ที่สุดต่อ (COUNTRY, INDEX_TYPE, COICOP_1999, FREQUENCY) — key นี้ verify
# แล้วว่าการันตี native Index unique 1 แถวต่อกลุ่มเสมอ (0 ซ้ำจากข้อมูลจริง
# ทั้งหมด) แต่ยังคงใส่ assertion ไว้เผื่อข้อมูลอนาคตผิดปกติ
imf_splice_cpi <- function(df) {
  key_cols <- c("COUNTRY", "INDEX_TYPE", "COICOP_1999", "FREQUENCY")

  native <- df %>% filter(TYPE_OF_TRANSFORMATION == "Index")
  srp    <- df %>% filter(TYPE_OF_TRANSFORMATION == "Standard reference period (2010=100), Index")
  other  <- df %>% filter(!TYPE_OF_TRANSFORMATION %in% c(
    "Index", "Standard reference period (2010=100), Index"))

  dupe_check <- native %>%
    count(across(all_of(c(key_cols, "TIME_PERIOD"))), name = "n") %>%
    filter(n > 1)
  if (nrow(dupe_check) > 0) {
    stop(sprintf(
      "imf_splice_cpi: splice key ไม่ unique — พบ %d กลุ่มที่มี native Index ซ้ำ. หยุดทันที ต้องตรวจสอบก่อน splice ต่อ",
      nrow(dupe_check)
    ))
  }

  # หา anchor ต่อ key group: จุดที่มีทั้ง native และ srp พร้อมกัน
  anchors <- native %>%
    select(all_of(key_cols), TIME_PERIOD, anchor_native = OBS_VALUE) %>%
    inner_join(
      srp %>% select(all_of(key_cols), TIME_PERIOD, anchor_srp = OBS_VALUE),
      by = c(key_cols, "TIME_PERIOD")
    )

  if (nrow(anchors) == 0) {
    message("imf_splice_cpi: ไม่พบ anchor เลย (native กับ srp ไม่เคย overlap) — คืน native อย่างเดียว")
    return(bind_rows(native, other))
  }

  # period_key: ใช้เทียบระยะ "ใกล้สุด" ระหว่าง anchor กับจุดที่ขาด native
  period_key <- function(p) {
    y <- as.integer(str_sub(p, 1, 4))
    rest <- str_sub(p, 6)
    m <- case_when(
      str_detect(p, "-Q") ~ (as.integer(str_sub(rest, 2)) - 1L) * 3L + 1L,
      str_detect(p, "-M") ~ as.integer(str_sub(rest, 2)),
      TRUE ~ 1L
    )
    y * 12L + m
  }

  missing_native <- srp %>%
    anti_join(native, by = c(key_cols, "TIME_PERIOD")) %>%
    select(all_of(key_cols), TIME_PERIOD, srp_val = OBS_VALUE) %>%
    mutate(pkey = period_key(TIME_PERIOD))

  anchors2 <- anchors %>% mutate(anchor_pkey = period_key(TIME_PERIOD)) %>%
    select(all_of(key_cols), anchor_pkey, anchor_native, anchor_srp)

  spliced <- missing_native %>%
    inner_join(anchors2, by = key_cols, relationship = "many-to-many") %>%
    group_by(across(all_of(c(key_cols, "TIME_PERIOD")))) %>%
    slice_min(abs(pkey - anchor_pkey), n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    transmute(across(all_of(key_cols)), TIME_PERIOD,
              OBS_VALUE = anchor_native * (srp_val / anchor_srp))

  # เติม column อื่นที่ native/srp มีร่วมกัน (SERIES_CODE ใช้ native's เป็น
  # ฐาน โดยแทน tag IX ให้รู้ว่าเป็นค่า spliced)
  template_cols <- setdiff(names(native), c(key_cols, "TIME_PERIOD", "OBS_VALUE"))
  template <- native %>% select(all_of(key_cols), all_of(template_cols)) %>% distinct(across(all_of(key_cols)), .keep_all = TRUE)

  spliced_full <- spliced %>%
    left_join(template, by = key_cols) %>%
    mutate(SERIES_CODE = paste0(SERIES_CODE, "_SPLICED"))

  cat(sprintf("imf_splice_cpi: เติม %d จุดที่ native Index ขาด (จาก SRP index + anchor)\n", nrow(spliced_full)))

  bind_rows(native, spliced_full, other)
}

# ── ER USD-only filter — ตัดสินใจ 2026-08-16: ER เก็บอัตราแลกเปลี่ยน
# bilateral หลายสกุล (Domestic vs USD/SDR/ECU/EUR) แต่ถ้ามีเรทเทียบ USD ของ
# ทุกประเทศครบแล้ว เรทคู่อื่น (เทียบ SDR/ECU/EUR) คำนวณคืนได้เองด้วย
# cross-rate (rate(A/B) = rate(A/USD) / rate(B/USD)) จึงเก็บไว้แค่คู่ USD
# พอ (2 ทิศทาง: Domestic per USD, USD per Domestic) ลด series ~70%
# โค้ด IMF ใช้ "USD" เป็น substring เสมอทั้ง bulk CSV (text: "US Dollar")
# และ live SDMX API (code: "XDC_USD"/"USD_XDC") — verify แล้วจากข้อมูลจริง
imf_filter_er_usd_only <- function(df) {
  if (!"INDICATOR" %in% names(df)) return(df)
  df[grepl("USD|US Dollar", df$INDICATOR, ignore.case = FALSE), ]
}

# ── เลือกความถี่ละเอียดสุดที่มีจริงต่อกลุ่ม (Monthly > Quarterly > Annual)
# — ตัดสินใจ 2026-08-16 สำหรับ CPI: ส่วนใหญ่มีครบ 3 ความถี่ซ้อนกันจากข้อมูล
# ชุดเดียวกัน (ไม่ใช่คนละชุด) เก็บแค่ที่ละเอียดสุดพอ ลด ~30% โดยไม่เสีย
# ประเทศที่มีแค่ Quarterly/Annual (เช่น New Zealand) ไปเลยแบบตัด Monthly-only
# ตรงๆ — ต้องกำหนด key_cols ให้ตรงกับ "series ที่แท้จริง" ของ dataset นั้น
# (รวม TYPE_OF_TRANSFORMATION ด้วยเสมอ เพราะ verify แล้วว่า Weight ก็มีหลาย
# ความถี่เหมือน Index ไม่ใช่แค่รายปี — ถ้า group ผิดจะเลือก freq ผิดฝั่ง)
# ── CPI/HICP recommended type ต่อประเทศ — ตัดสินใจ 2026-08-16: เก็บทั้ง
# CPI และ HICP ไว้ครบ (ไม่ตัดออก, dual-measurement ตาม Audit 3) แต่ติดป้าย
# เพิ่มว่าตัวไหนคือ "ตัวที่ระบบแนะนำ" ต่อประเทศ ใช้ไฟล์ data/imf_index_type.csv
# เดิม (ที่ fetch_imf_cpi.R ใช้อยู่แล้ว — 32 ประเทศที่มีทั้งคู่จริงๆ: 5
# ประเทศเลือก CPI, 27 ประเทศเลือก HICP) ประเทศที่ไม่อยู่ในไฟล์ (มีแค่แบบ
# เดียวอยู่แล้ว) fallback เป็น "CPI" เสมอ (ไม่มีผลจริงเพราะไม่มี HICP ให้เลือก)
IMF_CPI_INDEX_TYPE_MAP <- local({
  path <- "data/imf_index_type.csv"
  if (!file.exists(path)) return(character(0))
  df <- read.csv(path, stringsAsFactors = FALSE)
  setNames(df$index_type, df$iso3)
})

imf_cpi_recommended_type <- function(iso3) {
  rec <- unname(IMF_CPI_INDEX_TYPE_MAP[iso3])
  ifelse(is.na(rec), "CPI", rec)
}

# แยก "CPI"/"HICP" สั้นๆ จาก INDEX_TYPE ดิบ (เช่น "Consumer price index (CPI)"
# หรือ "Harmonised index of consumer prices (HICP)") — ใช้ regex จับคำใน
# วงเล็บท้ายสุด กันเปราะบางถ้า IMF เปลี่ยนคำเต็มแต่ตัวย่อในวงเล็บคงเดิม
imf_cpi_index_type_short <- function(index_type_raw) {
  # live SDMX API (Track 2) ส่ง INDEX_TYPE เป็นโค้ดสั้นตรงๆ เช่น "CPI" ไม่มี
  # วงเล็บแบบ bulk CSV (Track 1) เก่า — regmatches ไม่เจอ match จะคืน
  # character(0) (ไม่ใช่ "") ทำให้ full_name/meta$fullName กลายเป็น empty
  # vector และพัง Firestore PATCH ทุก row (บั๊กที่เจอจริง 2026-08-23 ตอน
  # fetch_imf_multi.R รันจริงครั้งแรกหลัง backfill) — กันด้วยเช็ค length ก่อน
  m <- regmatches(index_type_raw, regexpr("\\(([A-Z]+)\\)$", index_type_raw))
  if (length(m) == 0) return(index_type_raw)
  out <- gsub("[()]", "", m)
  if (nchar(out) == 0) index_type_raw else out
}

# ── ตัด CPI raw "Weight" ออก เหลือแค่ "Weight, Percent" — ตัดสินใจ
# 2026-08-16: verify แล้วว่าสอง field ครอบคลุม (ประเทศ×ประเภท×หมวด×ความถี่×
# ช่วงเวลา) เท่ากันเป๊ะ 100% (619,070 จุดทั้งคู่ ไม่มีจุดไหนขาดฝั่งใดฝั่งหนึ่ง)
# แต่ "Weight" ดิบใช้สเกลตามแต่ละประเทศเอง (บางประเทศฐาน 10/100/1000/10000/
# 100000 ไม่เท่ากัน) ส่วน "Weight, Percent" normalize ให้รวม 100 เสมอ —
# เก็บแค่ตัวหลัง เปรียบเทียบข้ามประเทศได้ตรงๆ ไม่เสี่ยงใช้ผิดสเกล
imf_cpi_drop_raw_weight <- function(df) {
  if (!"TYPE_OF_TRANSFORMATION" %in% names(df)) return(df)
  df[df$TYPE_OF_TRANSFORMATION != "Weight", ]
}

# ── PCPS: ตัด "Index" ทิ้งเฉพาะสินค้าที่มี "US dollars" คู่กันอยู่แล้ว —
# ตัดสินใจ 2026-08-16: verify แล้วว่า Index derivable จาก US dollars ตรงๆ
# (ratio คงที่เกือบสมบูรณ์ทุกสินค้า, coefficient of variation ≈ 0) แต่มี 28
# ดัชนีรวม (composite เช่น "Energy index", "All Metals Index") ที่มีแค่
# Index อย่างเดียว ไม่มี US dollars คู่กันเลย (ธรรมชาติของ composite index
# ไม่มีราคา $/หน่วยเดียว) — ห้ามตัด Index ของ 28 ตัวนี้ทิ้ง ไม่งั้นเสียไปเลย
imf_pcps_drop_redundant_index <- function(df) {
  if (!all(c("DATA_TRANSFORMATION", "INDICATOR") %in% names(df))) return(df)
  usd_indicators <- unique(df$INDICATOR[df$DATA_TRANSFORMATION == "US dollars"])
  drop_mask <- df$DATA_TRANSFORMATION == "Index" & df$INDICATOR %in% usd_indicators
  df[!drop_mask, ]
}

# ── IL: ตัด SDR ทิ้งเฉพาะ (ประเทศ, indicator) ที่มี US dollar คู่กันอยู่แล้ว
# — ตัดสินใจ 2026-08-16: verify แล้วว่า USD/SDR ratio เท่ากันทุกประเทศใน
# เวลาเดียวกัน (เช่น Germany/Japan/UK/US ratio=1.27 พร้อมกันหมด ณ ปี 2026)
# และเปลี่ยนตามเวลาจริง (1.0 ปี 1950 -> 1.37 ปัจจุบัน) ตรงกับอัตราแลกเปลี่ยน
# USD/SDR ทั่วโลก แปลว่า derivable จาก USD ด้วยเรตเดียวกันทุกประเทศ ไม่ใช่
# ต้องรู้อะไรเพิ่มเฉพาะประเทศ — แต่บาง indicator (เช่น "Gold reserves at 35
# SDRs per ounce" ซึ่งเป็นค่าตรึงประวัติศาสตร์) มีแค่ SDR อย่างเดียว ไม่มี
# USD คู่กันเลย ต้องเก็บไว้ ไม่ตัดทิ้ง (เหมือนกรณี PCPS's composite index)
imf_il_prefer_usd <- function(df) {
  if (!all(c("UNIT", "INDICATOR", "COUNTRY") %in% names(df))) return(df)
  key <- paste(df$COUNTRY, df$INDICATOR)
  usd_keys <- unique(key[df$UNIT == "US dollar"])
  drop_mask <- df$UNIT == "SDR" & key %in% usd_keys
  df[!drop_mask, ]
}

# ── ตัดแถว "Net (assets...)" ที่คำนวณคืนได้จาก Assets - Liabilities ของ
# indicator เดียวกัน — ใช้กับ MFS_CBS/MFS_ODC/MFS_FC/MFS_OFC (งบดุลสถาบัน
# การเงิน มีรูปแบบ "Net (assets minus/less liabilities), ..." ซ้ำกันหมด)
# ตัดสินใจ 2026-08-16: verify แล้วกับ MFS_CBS ว่า Net = Liabilities - Assets
# ตรงเป๊ะ (diff_pct median = 0 จาก 38,994 คู่ที่เทียบได้)
imf_drop_net_derived_rows <- function(df) {
  if (!"INDICATOR" %in% names(df)) return(df)
  df[!grepl("^Net \\(assets", df$INDICATOR), ]
}

# ── QNEA: เก็บเฉพาะ 18 indicator ที่เป็นองค์ประกอบหลักของ GDP (expenditure
# approach) ตัดรายละเอียดย่อย 9 ตัว (ภาษี/เงินอุดหนุน, แยกย่อยผู้บริโภคตาม
# สถาบัน, แยกย่อยสินค้าคงคลังตามภาคส่วน, valuables ที่ derivable) — ตัดสินใจ
# 2026-08-16 ร่วมกับ user ทีละตัว (ดู scratch_imf/DESIGN.md) ตัดได้แค่ 11.3%
# ของ series เพราะ 9 ตัวที่ตัดมีประเทศรายงานน้อยอยู่แล้ว (ส่วนใหญ่ <45
# ประเทศ) — ตัดเพื่อลดความสับสน (indicator ซ้อนกันเยอะ) ไม่ใช่เพื่อลดขนาด
IMF_QNEA_GDP_COMPONENTS <- c(
  "Gross domestic product (GDP)",
  "Final consumption expenditure",
  "Final consumption expenditure, General government",
  "Final consumption expenditure, Private sector",
  "Gross capital formation",
  "Gross fixed capital formation",
  "Changes in inventories",
  "Acquisitions less disposals of fixed assets: machinery and equipment",
  "Acquisitions less disposals of fixed assets: residential structures",
  "Acquisitions less disposals of fixed assets non-residential structures",
  "Exports of goods and services",
  "Exports of goods",
  "Exports of services",
  "Imports of goods and services",
  "Imports of goods",
  "Imports of services",
  "External balance of goods and services",
  "Statistical discrepancy (expenditure approach)"
)

imf_qnea_gdp_components_only <- function(df) {
  if (!"INDICATOR" %in% names(df)) return(df)
  df[df$INDICATOR %in% IMF_QNEA_GDP_COMPONENTS, ]
}

imf_finest_freq_only <- function(df, key_cols) {
  if (!"FREQUENCY" %in% names(df)) return(df)
  # ตัด key_cols ที่ไม่มีจริงใน df ออกอัตโนมัติ — Track 1 (bulk CSV) กับ
  # Track 2 (live SDMX API) บาง dataset มี column ไม่ตรงกันเป๊ะ (เช่น ITG's
  # VALUATION มีแค่ใน bulk CSV ไม่อยู่ใน dimension_order ของ live API) ถ้า
  # ไม่กันไว้ across(all_of()) จะ error ทันทีตอนรันจริงบน Track 2
  key_cols <- intersect(key_cols, names(df))
  # ทั้งคำเต็ม (bulk CSV export — Track 1/backfill) และโค้ดตัวย่อ (live SDMX
  # API — Track 2/fetch_imf_multi.R) ต้อง map ได้ — เจอบั๊กจริง 2026-08-23:
  # live API ส่ง FREQUENCY เป็น "M"/"Q"/"A" ไม่ใช่ "Monthly"/... ทำให้
  # freq_rank[df$FREQUENCY] ได้ NA ทุกแถว แล้ว filter เหลือ 0 แถวทั้ง dataset
  freq_rank <- c(Monthly = 3L, Quarterly = 2L, Annual = 1L, M = 3L, Q = 2L, A = 1L)
  df$.freq_rank <- unname(freq_rank[df$FREQUENCY])
  best <- df %>%
    group_by(across(all_of(key_cols))) %>%
    summarise(.best_rank = max(.freq_rank, na.rm = TRUE), .groups = "drop")
  df %>%
    left_join(best, by = key_cols) %>%
    filter(.freq_rank == .best_rank) %>%
    select(-.freq_rank, -.best_rank)
}

# ── period string -> Date, รองรับ "YYYY", "YYYY-Qn", "YYYY-Mnn"
imf_period_to_date <- function(period) {
  period <- as.character(period)
  out <- as.Date(rep(NA_character_, length(period)))
  is_m <- str_detect(period, "-M\\d{2}$")
  is_q <- str_detect(period, "-Q\\d$")
  is_y <- !is_m & !is_q & str_detect(period, "^\\d{4}$")

  if (any(is_m)) {
    y <- as.integer(str_sub(period[is_m], 1, 4))
    m <- as.integer(str_sub(period[is_m], -2))
    out[is_m] <- as.Date(sprintf("%d-%02d-01", y, m))
  }
  if (any(is_q)) {
    y <- as.integer(str_sub(period[is_q], 1, 4))
    q <- as.integer(str_sub(period[is_q], -1))
    out[is_q] <- as.Date(sprintf("%d-%02d-01", y, (q - 1L) * 3L + 1L))
  }
  if (any(is_y)) {
    out[is_y] <- as.Date(sprintf("%s-01-01", period[is_y]))
  }
  out
}

# ── ISO3 -> ชื่อประเทศเต็ม (265 ประเทศ) — เดิมเป็น IMF_ISO3_NAME hardcode
# ฝั่ง index.html เท่านั้น ย้ายมาไว้ที่ R ตาม schema ใหม่ (ตัดสินใจ 2026-08-22):
# R เป็นคนกำหนด label ทุกอย่างตอน push, เว็บอ่านอย่างเดียวไม่มี lookup table
# ของตัวเองอีกต่อไป (ที่มา: data/imf_country_names.csv สกัดจาก IMF_ISO3_NAME เดิม)
IMF_COUNTRY_NAME_MAP <- local({
  path <- "data/imf_country_names.csv"
  if (!file.exists(path)) return(character(0))
  df <- read.csv(path, stringsAsFactors = FALSE)
  setNames(df$name, df$iso3)
})

imf_country_name <- function(iso3) {
  nm <- unname(IMF_COUNTRY_NAME_MAP[iso3])
  if (length(nm) == 0 || is.na(nm)) iso3 else nm
}

# ── แปลง dimension_roles string (จาก imf_dataset_config.csv, comma list
# เรียงตรงกับ dimension_order) เป็น named vector: dim name -> role
# ("country"/"component"/"variant"/"fixed") ตัดสินใจร่วมกับ user 2026-08-22
# ระหว่างออกแบบ schema ใหม่ — role ต้องกำหนดต่อ dataset เพราะเดาจากชื่อ
# dimension อย่างเดียวไม่ได้ (INDICATOR ไม่ได้แปลว่า "component" เสมอไป)
imf_parse_dimension_roles <- function(dimension_order, dimension_roles) {
  dims  <- str_split(dimension_order, ",")[[1]]
  roles <- str_split(dimension_roles, ",")[[1]]
  setNames(roles, dims)
}

# ── slug: ข้อความอ่านง่ายจาก IMF (เช่น "Private sector consumption") ->
# code สั้นใช้ต่อ doc_id/query (ตัดอักขระที่ไม่ใช่ A-Za-z0-9 ทิ้ง, upper-case)
imf_dim_slug <- function(text) {
  s <- str_replace_all(as.character(text), "[^A-Za-z0-9]+", "_")
  s <- str_replace_all(s, "^_+|_+$", "")
  toupper(s)
}

# ── สร้าง "dims" field ของ schema ใหม่: เฉพาะ dimension ที่ role เป็น
# "component"/"variant" (ตัด "country" ออกเพราะแยกเป็น field ของตัวเองแล้ว,
# ตัด "fixed" ออกเพราะเป็นมิติที่ไม่ควรโผล่เป็นตัวเลือกในเมนู — เช่น
# FREQUENCY ที่ user ตัดสินใจ clean ข้อมูลให้เหลือ freq เดียวต่อ series แล้ว
# ไม่ต้องมีเป็น axis ในเมนูอีก) แต่ละ dim เก็บทั้ง code (ใช้ต่อ doc_id/query)
# + label (ข้อความอ่านง่ายจาก IMF ตรงๆ ไม่ต้องมี lookup table แปลซ้ำฝั่งเว็บ)
# + role (ฝัง role ไว้ในตัว doc เลย เว็บจะได้ไม่ต้องมี config อีกไฟล์แยก —
# ตัดสินใจ 2026-08-22 ปิด sync-2-ที่ ที่เคยเป็นปัญหากับ IMF_DATASET_INFO เดิม)
imf_build_dims <- function(dim_values, roles, dsd_info = NULL) {
  dims <- list()
  for (nm in names(dim_values)) {
    role <- unname(roles[nm])
    if (is.na(role) || role %in% c("country", "fixed")) next
    val <- dim_values[[nm]]
    label <- if (!is.null(dsd_info)) imf_label_lookup(dsd_info, nm, as.character(val)) else as.character(val)
    dims[[nm]] <- list(code = imf_dim_slug(val), label = label, role = role)
  }
  dims
}

# ── ดึง codelist (code -> ชื่ออ่านง่าย) ของทุก dimension ใน DSD จาก IMF
# Structure API มาครั้งเดียวต่อ dataset — live SDMX data fetch
# (imf_fetch_wildcard) คืนค่า dimension เป็น "code" ดิบเสมอ (เช่น INDICATOR
# ของ CTOT = "CEMPI_CTOTNX_TT") ไม่ใช่ label อ่านง่าย ต่างจาก bulk CSV ที่ใช้
# backfill ซึ่งมี text column แยกให้อยู่แล้ว — บาง dataset code ดิบบังเอิญ
# เป็นคำอังกฤษเต็มอยู่แล้ว (เช่น QNEA's PRICE_TYPE = "Nominal") เลยดูปกติ
# ทั้งที่ไม่ได้ผ่าน lookup นี้เลย แต่ dataset อื่น (CTOT, QGDP_WCA, และบาง
# indicator ใน EER/ER/ITG/PPI) code ดิบอ่านไม่รู้เรื่อง (เจอจริงจาก user
# report 2026-08-25: "CEMPI_CTOTNX_TT" โผล่ตรงๆ ใน series picker) — DSD
# (?references=all) มีทั้ง Dimension->Codelist mapping และตัว Codelist
# (code->Name) มาในคำขอเดียว ไม่ต้องเดา codelist id เอง (ลอง guess
# CL_{dataset}_{dim} มาก่อนแล้วพบว่าไม่ตรงรูปแบบเสมอไป เช่น QNEA's
# INDICATOR ใช้ CL_NEA_INDICATOR ไม่ใช่ CL_QNEA_INDICATOR)
imf_fetch_dsd_codelists <- function(agency, dsd_id, version, timeout_sec = 120) {
  empty <- list(dim_to_codelist = list(), codelists = list())
  url <- sprintf("https://api.imf.org/external/sdmx/2.1/datastructure/%s/%s/%s?references=all",
                  agency, dsd_id, version)
  resp <- tryCatch(
    request(url) |> req_headers(`User-Agent` = "Mozilla/5.0") |>
      req_timeout(timeout_sec) |> req_error(is_error = \(r) FALSE) |> req_perform(),
    error = function(e) NULL
  )
  if (is.null(resp) || resp_status(resp) >= 300) {
    warning(sprintf("imf_fetch_dsd_codelists: %s/%s failed to fetch DSD structure (status %s)",
                     agency, dsd_id, if (is.null(resp)) "NA" else resp_status(resp)))
    return(empty)
  }
  doc <- tryCatch(read_xml(resp_body_string(resp)), error = function(e) NULL)
  if (is.null(doc)) return(empty)

  dim_nodes <- xml_find_all(doc, "//*[local-name()='DimensionList']/*[local-name()='Dimension']")
  dim_to_cl <- list()
  for (dn in dim_nodes) {
    did <- xml_attr(dn, "id")
    ref <- xml_find_first(dn, ".//*[local-name()='Enumeration']/*[local-name()='Ref']")
    cl_id <- xml_attr(ref, "id")
    if (!is.na(cl_id)) dim_to_cl[[did]] <- cl_id
  }

  cl_nodes <- xml_find_all(doc, "//*[local-name()='Codelist']")
  codelists <- list()
  for (cn in cl_nodes) {
    cl_id <- xml_attr(cn, "id")
    code_nodes <- xml_find_all(cn, "./*[local-name()='Code']")
    if (length(code_nodes) == 0) next
    ids <- vapply(code_nodes, function(x) xml_attr(x, "id"), character(1))
    names_ <- vapply(code_nodes, function(x) {
      nm <- xml_find_first(x, ".//*[local-name()='Name'][@xml:lang='en']")
      if (is.na(nm)) xml_attr(x, "id") else xml_text(nm)
    }, character(1))
    codelists[[cl_id]] <- setNames(as.list(names_), ids)
  }
  list(dim_to_codelist = dim_to_cl, codelists = codelists)
}

# ── code ดิบของ dimension หนึ่งตัว -> label อ่านง่าย (ถ้าหาไม่เจอใน
# codelist ก็คืน code เดิมกลับไป ไม่ทำให้ pipeline พังหรือชื่อหายไปเฉยๆ)
imf_label_lookup <- function(dsd_info, dim_id, code) {
  cl_id <- dsd_info$dim_to_codelist[[dim_id]]
  if (is.null(cl_id)) return(code)
  lbl <- dsd_info$codelists[[cl_id]][[code]]
  if (is.null(lbl) || is.na(lbl) || !nzchar(lbl)) code else lbl
}

# ── doc_id: derive-forward จาก dims ที่ผ่าน imf_build_dims() มาแล้ว
# (component code มาก่อน ตามด้วย variant code ตามลำดับใน dimension_order)
# ไม่ parse doc_id ย้อนกลับอีกต่อไปเหมือนเวอร์ชันเดิม (ตัดสินใจ 2026-08-22:
# ไม่ต้องคง backward-compat กับ doc_id เดิม เพราะไม่มี Excel/VBA user ผูกไว้จริง)
imf_build_doc_id <- function(dataset_id, country_iso3, dims) {
  codes <- vapply(dims, function(d) d$code, character(1))
  suffix <- paste(codes, collapse = "_")
  sprintf("IMF_%s_%s_%s", country_iso3, dataset_id, suffix)
}

# ── generic SDMX 2.1 wildcard fetch: key เป็น dot ว่างทุก dimension
# (ยกเว้น TIME ที่คุมด้วย startPeriod) — ดึงทุกประเทศ ทุกค่าของทุกมิติ
# มาในคำขอเดียว แล้วกรอง %change/splice ทีหลังฝั่ง client (Track 2, ใช้
# กับ startPeriod แบบ rolling window ~2 ปี ไม่ใช่ full history)
suppressPackageStartupMessages({ library(httr2); library(xml2) })

imf_fetch_wildcard <- function(agency, dataset_id, version, n_dims,
                                start_period, timeout_sec = 180) {
  # SDMX key ต้องการจำนวน segment ที่ "ถูกต้อง" ต่อ dataset แต่พบว่า IMF's
  # backend ไม่สม่ำเสมอ: บาง dataset (PPI, FSIC) ต้องการ segment เท่ากับ
  # n_dims เป๊ะ (500 error ถ้าน้อยกว่า), บาง dataset (EER) กลับต้องการ
  # segment น้อยกว่า n_dims (500 error ถ้าเท่ากับ n_dims) — เจอจริงระหว่าง
  # ทดสอบ ไม่ใช่ error ที่คาดเดาได้จาก DSD ล่วงหน้า จึงต้อง retry ไล่ตั้งแต่
  # n_dims segment ลงมาทีละ 1 จนกว่าจะสำเร็จ (หรือหมดตัวเลือก)
  resp <- NULL
  used_n_seg <- NA_integer_
  for (n_seg in seq(n_dims, 1)) {
    key <- paste(rep("", n_seg), collapse = ".")
    url <- sprintf("https://api.imf.org/external/sdmx/2.1/data/%s,%s,%s/%s?startPeriod=%s",
                    agency, dataset_id, version, key, start_period)
    resp <- tryCatch(
      request(url) |>
        req_headers(`User-Agent` = "Mozilla/5.0") |>
        req_timeout(timeout_sec) |>
        req_error(is_error = \(r) FALSE) |>
        req_perform(),
      error = function(e) NULL
    )
    if (!is.null(resp) && resp_status(resp) < 300) { used_n_seg <- n_seg; break }
  }
  if (is.null(resp) || resp_status(resp) >= 300) {
    warning(sprintf("imf_fetch_wildcard: %s/%s failed after trying all segment counts (status %s)",
                     agency, dataset_id, if (is.null(resp)) "NA" else resp_status(resp)))
    return(tibble())
  }
  if (used_n_seg != n_dims) {
    message(sprintf("  (note: %s needed %d key segment(s), not %d as expected from DSD dimension count)",
                     dataset_id, used_n_seg, n_dims))
  }

  doc <- tryCatch(read_xml(resp_body_string(resp)), error = function(e) NULL)
  if (is.null(doc)) return(tibble())

  series_nodes <- xml_find_all(doc, "//*[local-name()='Series']")
  if (length(series_nodes) == 0) return(tibble())

  rows <- map(series_nodes, function(s) {
    series_attrs <- as.list(xml_attrs(s))
    obs <- xml_find_all(s, ".//*[local-name()='Obs']")
    if (length(obs) == 0) return(NULL)
    obs_attrs <- map(obs, ~as.list(xml_attrs(.x)))
    obs_df <- bind_rows(obs_attrs)
    if (!"OBS_VALUE" %in% names(obs_df) || !"TIME_PERIOD" %in% names(obs_df)) return(NULL)
    obs_df$OBS_VALUE <- suppressWarnings(as.numeric(obs_df$OBS_VALUE))
    obs_df <- obs_df[!is.na(obs_df$OBS_VALUE), c("TIME_PERIOD", "OBS_VALUE")]
    if (nrow(obs_df) == 0) return(NULL)
    for (nm in names(series_attrs)) obs_df[[nm]] <- series_attrs[[nm]]
    obs_df
  })
  bind_rows(compact(rows))
}

# ── currency ที่ detect ได้จาก text field ต่างๆ (ใช้เติม meta$currency)
imf_detect_currency <- function(text_vals) {
  txt <- paste(na.omit(text_vals), collapse = " | ")
  if (str_detect(txt, "(?i)us dollar")) return("USD")
  if (str_detect(txt, "(?i)\\beuro\\b")) return("EUR")
  if (str_detect(txt, "(?i)domestic currency")) return("Domestic Currency")
  if (str_detect(txt, "(?i)\\bSDR\\b")) return("SDR")
  ""
}
