# wrapper รัน local แทน .github/workflows/daily_news.yml (cron ปิดชั่วคราว — ดู TEMP-DISABLED-2026-08)
# FIREBASE_TOKEN ต่างจาก secret อื่น — ไม่ได้เก็บนิ่งใน Credential Manager
# เพราะเป็น OAuth access token อายุ ~1 ชม. ต้อง gen สดทุกครั้งจาก GCP_SA_KEY
# ผ่าน get_access_token() ตัวเดียวกับที่สคริปต์อื่นใช้ (R/firestore.R)
repo_root <- "C:/Users/limhe/OneDrive/Documents/GitHub/macroindicator"
setwd(repo_root)
source("load_secret.R")
load_secret("GCP_SA_KEY")
load_secret("GEMINI_API_KEY")
load_secret("FT_COOKIE")
Sys.setenv(FIREBASE_URL = "https://firestore.googleapis.com/v1/projects/macroindicator-6b265/databases/(default)/documents")

suppressPackageStartupMessages({
  library(jsonlite)
  library(httr2)
  library(jose)
})
source("R/firestore.R")
sa <- fromJSON(Sys.getenv("GCP_SA_KEY"))
Sys.setenv(FIREBASE_TOKEN = get_access_token(sa))

setwd(file.path(repo_root, "news-pipeline"))
source("fetch_news.R")
