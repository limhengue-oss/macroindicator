# ══════════════════════════════════════════════════════════════════
#  push_oil_prices_sg_backfill.R
#  Backfill ราคาน้ำมันสิงคโปร์ (ULG95_SG / DIESEL_SG) ที่ผู้ใช้เก็บเองรายวันไว้ใน
#  eppo_sample.xlsx (คอลัมน์ "SG_ULG95 (PEIT)" / "SG_HSD (10ppm)") ย้อนหลัง
#  เข้า collection `oil_prices` — collection เดียวกับที่ Cloud Function
#  lineOilWebhook (functions/index.js) เขียนทุกวันจากข้อความ broadcast ของ
#  PEIT LINE OA (ดู functions/parseOilMessage.js: ULG 95 (S'pore) -> ULG95_SG,
#  GO 0.001%S -> DIESEL_SG — ตรงกับ "10ppm" ในไฟล์ผู้ใช้เป๊ะ, 0.001%S = 10ppm)
#
#  doc id = วันที่ (YYYY-MM-DD) ตรงกับ pattern ของ webhook — เขียนด้วย PATCH +
#  updateMask จำกัดเฉพาะ ULG95_SG/DIESEL_SG (ไม่แตะ `receivedAt` ที่ webhook
#  อาจเขียนไว้แล้วสำหรับวันที่ทับซ้อนช่วงปลาย) ปลอดภัยรันซ้ำได้ (idempotent)
#
#  input: workfile/oil_prices_sg_backfill.csv (สร้างจาก eppo_sample.xlsx,
#  6,743 แถว, 2002-02-01 ถึง 2026-08-19 — ULG95_SG มีทั้งช่วง, DIESEL_SG มีตั้งแต่
#  2020-07-01 เท่านั้นเพราะไฟล์ต้นทางไม่มีข้อมูลก่อนหน้านั้น)
#
#  one-off script — ยังไม่เคยรัน ตรวจสอบ CSV ให้ดีก่อนรันจริง
#  รัน (จาก repo root): Rscript scripts/oneoff/push_oil_prices_sg_backfill.R
# ══════════════════════════════════════════════════════════════════

suppressPackageStartupMessages({
  library(httr2); library(jsonlite); library(jose)
  library(dplyr); library(readr); library(purrr)
})

PROJECT_ID <- "macroindicator-6b265"
COLLECTION <- "oil_prices"
CSV_PATH   <- "workfile/oil_prices_sg_backfill.csv"
BATCH_SIZE <- 400  # Firestore commit endpoint จำกัด 500 writes/request

sa_json <- Sys.getenv("GCP_SA_KEY")
if (sa_json == "") stop("GCP_SA_KEY not set")
sa <- fromJSON(sa_json)

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

# PATCH 1 doc ต่อวันที่ — updateMask จำกัดเฉพาะ field ที่มีค่าจริงในแถวนั้น
# (บาง field ก่อน 2020-07 ไม่มี DIESEL_SG — อย่าเขียนทับด้วย null)
push_one <- function(token, date_str, ulg, dsl) {
  fields <- list()
  mask   <- c()
  if (!is.na(ulg)) { fields$ULG95_SG  <- list(doubleValue = ulg); mask <- c(mask, "ULG95_SG") }
  if (!is.na(dsl)) { fields$DIESEL_SG <- list(doubleValue = dsl); mask <- c(mask, "DIESEL_SG") }
  if (length(mask) == 0) return(invisible(NULL))

  url <- sprintf(
    "https://firestore.googleapis.com/v1/projects/%s/databases/(default)/documents/%s/%s",
    PROJECT_ID, COLLECTION, date_str
  )
  resp <- request(url) |>
    req_url_query(`updateMask.fieldPaths` = mask, .multi = "explode") |>
    req_method("PATCH") |>
    req_auth_bearer_token(token) |>
    req_body_json(list(fields = fields), auto_unbox = TRUE) |>
    req_error(is_error = \(r) FALSE) |> req_perform()

  if (resp_status(resp) >= 300) {
    warning(sprintf("  ✗ %s HTTP %d", date_str, resp_status(resp)))
    return(FALSE)
  }
  TRUE
}

# ── Main ──────────────────────────────────────────────────────────
message("── Reading ", CSV_PATH)
df <- read_csv(CSV_PATH, col_types = cols(
  date = col_date(), ULG95_SG = col_double(), DIESEL_SG = col_double()
))
df <- df |> filter(!is.na(date)) |> arrange(date) |> distinct(date, .keep_all = TRUE)
message(sprintf("  %d rows, %s → %s", nrow(df), min(df$date), max(df$date)))
message(sprintf("  ULG95_SG: %d rows, DIESEL_SG: %d rows",
                sum(!is.na(df$ULG95_SG)), sum(!is.na(df$DIESEL_SG))))

message("── Authenticating...")
token <- get_token(sa)
message("  ✓ token OK")

message("── Pushing to Firestore (", COLLECTION, ")...")
ok <- 0; fail <- 0
for (i in seq_len(nrow(df))) {
  r <- push_one(token, as.character(df$date[i]), df$ULG95_SG[i], df$DIESEL_SG[i])
  if (isTRUE(r)) ok <- ok + 1 else if (isFALSE(r)) fail <- fail + 1
  if (i %% 200 == 0) {
    message(sprintf("  ... %d/%d (ok=%d, fail=%d)", i, nrow(df), ok, fail))
    token <- get_token(sa)  # token หมดอายุ 1 ชม. — 6,743 แถวอาจใช้เวลาเกิน รีเฟรชกันเหนียว
  }
}

message(sprintf("\n✓ Backfill done — ok=%d, fail=%d, total=%d", ok, fail, nrow(df)))
