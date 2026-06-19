# Macro Dashboard

Architecture:
```
GitHub Actions (cron 6h) → R (tidyquant + fredr) → Firestore → index.html
```

## Files
- `fetch_and_push.R` — ดึงข้อมูล + push ขึ้น Firestore
- `index.html` — dashboard อ่านจาก Firestore
- `.github/workflows/update-data.yml` — cron job ทุก 6 ชม.
- `firestore.rules` — public read, server-only write

## Setup

### 1. GitHub Secrets
ไปที่ repo Settings → Secrets and variables → Actions → New repository secret:
- `FRED_API_KEY` = FRED API key
- `GCP_SA_KEY` = เนื้อหาทั้งหมดของ service-account.json (paste ทั้งก้อน)

### 2. Firestore Rules
Firebase Console → Firestore → Rules → paste จาก `firestore.rules` → Publish

### 3. ทดสอบ local (optional)
```bash
export FRED_API_KEY="your_fred_key"
export GCP_SA_KEY="$(cat service-account.json)"
Rscript fetch_and_push.R
```
แล้วเปิด index.html

### 4. Deploy dashboard
GitHub Pages: Settings → Pages → Branch main → Save
หรือเปิด index.html จาก local ได้เลย (Firestore SDK รองรับ file://)

### 5. รัน workflow ครั้งแรก
Actions tab → Update Macro Data → Run workflow (กดเอง) เพื่อ seed ข้อมูลครั้งแรก
หลังจากนั้นจะรันอัตโนมัติทุก 6 ชม.

## Series catalog
แก้ `CATALOG` ใน fetch_and_push.R เพื่อเพิ่ม/ลบ series
