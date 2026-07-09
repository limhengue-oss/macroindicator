# Macro Dashboard

Static dashboard (`index.html`) ที่อ่านข้อมูลจาก Firestore โดยตรง (Firebase JS SDK ฝั่ง client) ไม่มี backend server — ข้อมูลถูกดึง/อัปเดตโดย GitHub Actions ที่รัน R script เป็นรอบๆ แล้ว push เข้า Firestore

```
GitHub Actions (cron)  →  R (tidyquant / fredr / rvest / pdftools)  →  Firestore  →  index.html (client อ่านตรง)
```

เปิดใช้งานได้ทั้งจาก GitHub Pages หรือเปิดไฟล์ `index.html` local ตรงๆ (Firestore SDK รองรับ `file://`)

---

## วิธีใช้แต่ละหน้า (Pages)

Nav bar ด้านบนมี 2 หน้าพิเศษที่มากับระบบ (News, TH Energy) และหน้าที่ผู้ใช้สร้างเองได้ไม่จำกัด (ปุ่ม `+` ท้าย nav)

### 1. News
ข่าวรายวันที่ดึงมาจาก Firestore collection `daily_news` — จัดกลุ่มตามวันที่ (ใหม่สุดอยู่บนสุด) แต่ละข่าวแสดง source, หัวข้อ (คลิกเพื่อเปิดลิงก์ต้นฉบับ), สรุปภาษาไทย และ "เหตุผลที่เลือกข่าวนี้" กด **↻ Refresh** เพื่อโหลดข่าวใหม่

### 2. TH Energy — ราคาพลังงานไทย
หน้าเฉพาะทางสำหรับติดตามราคาน้ำมัน/LPG/FO และฐานะกองทุนน้ำมัน แสดงเป็นการ์ดต่อผลิตภัณฑ์:

- **การ์ดราคาน้ำมัน** (Diesel, Gasohol 95/91, E20, E85, ULG 95, LPG, FO 1500, FO 600):
  - ราคาล่าสุด, ค่าเฉลี่ย MTD/QTD พร้อม %YoY เทียบช่วงเดียวกันปีก่อน
  - ถ้าตั้ง **Reference Date** ไว้ (ดูหัวข้อ Options ด้านล่าง) จะมีคอลัมน์ "vs วันที่อ้างอิง" เพิ่มมาเทียบ % เปลี่ยนแปลงด้วย
  - กราฟรายปี (เส้นสีส้ม = ปีนี้, เส้นเทา = ปีก่อน) overlay กันดูฤดูกาล
  - กด **"โครงสร้างราคา"** (ในการ์ด) เพื่อดู breakdown ราคาทุกองค์ประกอบ (Ex-Refinery, Excise Tax, กองทุนน้ำมัน, VAT, Marketing Margin ฯลฯ) ณ วันล่าสุด เทียบกับ ณ Reference Date
- **การ์ด Oil Fund Status** (ฐานะกองทุนน้ำมันสุทธิ): กราฟ timeseries เต็มช่วงประวัติของ `net_total` (ล้านบาท) พร้อมมูลค่าล่าสุด ต่อท้ายการ์ดราคาน้ำมันทั้งหมด
- ปุ่ม **ℹ โครงสร้างราคา** (มุมขวาบนของหน้า): เปิด popup อธิบายโครงสร้างราคาน้ำมันไทยแบบละเอียด (เนื้อหาจาก `eppo_structure.md`)
- ปุ่ม **⬇ Export PDF**: สร้าง PDF สรุปเฉพาะ Diesel + Gasohol 95 (พร้อม breakdown เปิดอยู่) จัด layout 2 คอลัมน์ A4 แนวนอน 1 หน้า — ใช้เวลาสักครู่ให้รอจนปุ่มเปลี่ยนกลับเป็นข้อความเดิม

### 3. หน้าที่สร้างเอง (Custom Pages)
กด **`+`** ท้าย nav bar เพื่อสร้างหน้าใหม่ — ตั้งชื่อและจำนวนคอลัมน์ (Auto หรือ 1–8)

ในแต่ละหน้า:
- **+ Chart**: เพิ่มกราฟใหม่ ตั้งชื่อ, เลือก series ได้ 1–8 เส้นต่อกราฟ (แต่ละเส้นเลือก Axis ซ้าย/ขวา, Function, สี แยกกันได้), ตั้ง default period
- **Function ต่อ series**: `raw` (ค่าจริง) · `norm` (base 100 ณ ต้นช่วงที่เลือก) · `cumret` (%สะสมจากต้นช่วง) · `yoy` (%เทียบปีก่อน) · `mom` (%เทียบเดือนก่อน) · `ma20`/`ma50` (moving average)
- **Timeframe ต่อการ์ด**: ปุ่ม 3M/6M/1Y/3Y/10Y/Max ใต้หัวการ์ดแต่ละใบ
- **All: [period] / Per chart** (มุมซ้ายบนของหน้า): ตั้ง period เดียวกันทุกกราฟในหน้าพร้อมกัน หรือกลับไปให้แต่ละการ์ดจำ period ของตัวเอง (Per chart)
- **✎ Edit / ✕ Delete** บนแต่ละการ์ด: แก้ไข/ลบกราฟนั้น
- **Edit page / Delete** (หัวหน้า): แก้ชื่อ/จำนวนคอลัมน์ หรือลบทั้งหน้า
- **ℹ (บนการ์ด)**: ดู metadata ของแต่ละ series ในกราฟนั้น (ชื่อเต็ม, หน่วย, สกุลเงิน, ความถี่, แหล่งข้อมูล, วันที่อัปเดตล่าสุด)

Series ที่เลือกได้จัดเป็นหมวดใน dropdown: US Equity, Mag 7, Crypto, EU/Asia Indices, SET Industry/Sector, FX, Commodities, US/EU Macro, EPPO (ราคาขายปลีก/ขายส่ง + กองทุนน้ำมันของแต่ละผลิตภัณฑ์), PTT OR Oil

> **หมายเหตุ:** custom pages/charts เก็บไว้ใน `localStorage` ของเบราว์เซอร์เท่านั้น (ไม่ sync ข้ามเครื่อง/อุปกรณ์) ถ้าต้องการย้ายหรือสำรองไว้ ให้ใช้ Export/Import ใน Options (ดูด้านล่าง)

### 4. Options (ปุ่ม ⚙ มุมขวาบน)
- **Theme**: Dark / Light
- **Font size**: 100–300% (กราฟและการ์ดจะปรับขนาดตาม)
- **Reference Date**: อ่านจาก `data/ref_dates.txt` (วันที่ล่าสุดที่ ≤ วันนี้) ใช้เป็นวันฐานเทียบราคาในหน้า TH Energy — ถ้าอยากเปลี่ยนวันอ้างอิง แก้ไฟล์ `data/ref_dates.txt` แล้ว refresh
- **Export / Import**: บันทึก/โหลดค่า config ของ custom pages+charts ทั้งหมดเป็นไฟล์ `macro-config.json`

---

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
Rscript fetch_eppo.R
```
แล้วเปิด `index.html`

### 4. Deploy dashboard
GitHub Pages: Settings → Pages → Branch main → Save
หรือเปิด `index.html` จาก local ได้เลย (Firestore SDK รองรับ `file://`)

### 5. รัน workflow ครั้งแรก
Actions tab → **Update Macro Data** → Run workflow (กดเอง) เพื่อ seed ข้อมูลครั้งแรก หลังจากนั้นจะรันอัตโนมัติทุก 6 ชม.

ถ้าต้องการ backfill ข้อมูลฐานะกองทุนน้ำมันย้อนหลัง (ครั้งเดียว จาก `workfile/offo_parsed.csv`): Actions tab → **Backfill Oil Fund Status** → Run workflow

---

## Files
- `fetch_and_push.R` — ดึงข้อมูล FRED/Yahoo (tidyquant + fredr) → push ขึ้น Firestore
- `fetch_eppo.R` — scrape ราคาน้ำมัน EPPO/OFFO + ฐานะกองทุนน้ำมัน (offo.or.th) → push ขึ้น Firestore ทุกวัน
- `push_meta_only.R` — push metadata (ชื่อเต็ม/หน่วย/แหล่งข้อมูล) ของแต่ละ series แยกต่างหาก (รันมือ ไม่ auto)
- `push_oilfund_backfill.R` — push ประวัติฐานะกองทุนน้ำมันจาก `workfile/offo_parsed.csv` ครั้งเดียว
- `index.html` — dashboard อ่านจาก Firestore (client-side)
- `eppo_structure.md` — เนื้อหา popup "โครงสร้างราคาน้ำมัน" ในหน้า TH Energy
- `data/ref_dates.txt` — รายการวันที่ที่เลือกเป็น Reference Date ได้ในหน้า TH Energy
- `.github/workflows/update-data.yml` — cron job ทุก 6 ชม. (fetch_and_push.R + fetch_eppo.R)
- `.github/workflows/push-metadata.yml` — รัน push_meta_only.R (manual trigger)
- `.github/workflows/backfill-oilfund.yml` — รัน push_oilfund_backfill.R (manual trigger, ใช้ครั้งเดียว)
- `.github/workflows/daily_news.yml` — ดึงข่าวรายวันเข้า Firestore
- `firestore.rules` — public read, server-only write

## Series catalog
แก้ `CATALOG` ใน `fetch_and_push.R` เพื่อเพิ่ม/ลบ series ทั่วไป, แก้ `SERIES_GROUPS` ใน `index.html` เพื่อจัดหมวดหมู่ใน dropdown เลือก series
