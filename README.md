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

Series ที่เลือกได้จัดเป็นหมวดใน dropdown: US Equity, Mag 7, Crypto, EU/Asia Indices, SET Industry/Sector, FX, Commodities, US/EU Macro, Thailand Macro (BOT), Thailand Bond Yield (ThaiBMA, Daily), EPPO (ราคาขายปลีก/ขายส่ง + กองทุนน้ำมันของแต่ละผลิตภัณฑ์), PTT OR Oil

> **หมายเหตุ:** custom pages/charts เก็บไว้ใน `localStorage` ของเบราว์เซอร์เท่านั้น (ไม่ sync ข้ามเครื่อง/อุปกรณ์) ถ้าต้องการย้ายหรือสำรองไว้ ให้ใช้ Export/Import ใน Options (ดูด้านล่าง)

### 4. Options (ปุ่ม ⚙ มุมขวาบน)
- **Theme**: Dark / Light
- **Font size**: 100–300% (กราฟและการ์ดจะปรับขนาดตาม)
- **Reference Date**: อ่านจาก `data/ref_dates.txt` (วันที่ล่าสุดที่ ≤ วันนี้) ใช้เป็นวันฐานเทียบราคาในหน้า TH Energy — ถ้าอยากเปลี่ยนวันอ้างอิง ต้องแก้ไฟล์ `data/ref_dates.txt` แล้ว refresh
- **Export / Import**: บันทึก/โหลดค่า config ของ custom pages+charts ทั้งหมดเป็นไฟล์ `macro-config.json`
