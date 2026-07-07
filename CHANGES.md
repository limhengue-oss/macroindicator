# Changelog

## v5.5.4 — 2026-07-07

### index.html

- **Cum%/base 100 (norm) คำนวณผิด** — เป็น regression จากตอนแก้ MA/YoY/MoM ใน
  v5.2c: ตอนนั้นสลับลำดับเป็น "apply function ก่อน cut period" เพื่อให้
  MA20/50 และ YoY/MoM มีข้อมูลย้อนหลังพอ แต่ลืมว่า `norm`/`cumret` ต้องการ
  base เป็น**จุดแรกของช่วงที่เลือกดู** ไม่ใช่จุดแรกสุดของประวัติทั้งหมด — ผลคือ
  เลือกดู period สั้น ๆ (เช่น 3M) แล้ว Cum% กลับเทียบกับราคาเมื่อหลายปีก่อน
  (จุดเริ่มต้นของ full series) แทนที่จะเทียบกับราคาต้นช่วง 3M ทำให้ตัวเลข % ที่
  แสดงผิดเพี้ยนไปมาก
  **แก้:** แยก logic ตาม fn — `norm`/`cumret` ยังคง cut ก่อนแล้วค่อย apply
  (base = จุดแรกของช่วงที่เลือก) ส่วน `ma20`/`ma50`/`yoy`/`mom` ยังคง apply
  ก่อนแล้วค่อย cut เหมือนเดิม (ต้องการ lookback ข้ามช่วง)

### push_meta_only.R

- **Metadata popup (ปุ่ม ℹ) แสดงแค่ "Updated" ไม่มี Full name/Unit/Source ฯลฯ**
  สำหรับ series กลุ่ม EPPO — สาเหตุคือ `CATALOG` ใน `push_meta_only.R` (ที่ดึง
  metadata จาก Yahoo/FRED แล้ว patch เข้า Firestore) **ไม่เคยมี EPPO_* อยู่เลย**
  ทำให้ field `meta` ของ series พวกนี้ไม่เคยถูกเขียนใน Firestore (เห็นแค่
  `updated` เพราะเป็นคนละ field ที่ทุกสคริปต์ fetch เขียนอยู่แล้ว)
  **แก้:** เพิ่ม `EPPO_PRODUCTS` + `STATIC_CATALOG` — hardcode metadata
  (fullName, unit, source="EPPO (old.eppo.go.th)") ให้ทุก EPPO series (ทั้ง
  field หลักและ Oil Fund ของทั้ง 9 ผลิตภัณฑ์ใน `EPPO_ORDER`) แล้ว patch เข้า
  Firestore ต่อจาก CATALOG เดิม — ต้อง trigger workflow "Push Series Metadata"
  ใหม่ (เป็น `workflow_dispatch` ต้องกดรันเอง) เพื่อให้ข้อมูลจริงอัพเดท

## v5.5.3 — 2026-07-07

### fetch_eppo.R

- **เพิ่ม "missing products" check กลับเข้าไป** ที่หายไปตอน rewrite เป็น
  2-step OFFO+EPPO (ดู v5.5.2) — `parse_xlsx()` รับ `meta_products` เพิ่ม
  (base product list จาก `meta/eppo_status`) หลัง parse ไฟล์เสร็จจะเทียบ
  `unique(df$BASE_PRODUCT)` กับ `meta_products`: ถ้าขาด → `return(NULL)`
  ทั้งไฟล์ทันที (all-or-nothing ต่อวัน ไม่ push ข้อมูลครึ่ง ๆ กลาง ๆ) พร้อม
  message บอกว่าขาด product ตัวไหน
  - ดึง `meta_products` ครั้งเดียวใน MAIN หลังอ่าน meta/eppo_status ตอนเริ่ม
    สคริปต์ แล้วส่งต่อให้ `download_and_parse()` → `parse_xlsx()` ทั้ง 2 step
    (OFFO และ EPPO)

## v5.5.2 — 2026-07-07 (bugfix pass)

### index.html

- **`--bg3` เพี้ยนจาก `#1c1c1e` เป็น `#1d1e1c` โดยไม่ตั้งใจ** (เข้าใจว่าหลุดมา
  จากการแก้ไขก่อนหน้านี้ในเซสชัน) — คืนค่าเดิม
- **PDF export ไม่ได้ขยายความสูงกราฟจริง** — CSS
  `#energy-boxes.pdf-export .energy-chart-box { height:220px }` ไม่มี
  `!important` เลยแพ้ inline `style="height:140px"` ที่ติดอยู่บน element เดิม
  (inline style ชนะ CSS ปกติเสมอ ยกเว้น CSS นั้นมี `!important`) ทำให้กราฟ
  ตอน export PDF ยังคงสูงแค่ 140px เหมือนตอนแสดงบนจอ ไม่ได้ขยายเป็น 220px
  ตามที่ตั้งใจ — เพิ่ม `!important` ให้ถูกต้อง

### fetch_eppo.R (พบขณะรีวิว — ไฟล์ถูกแก้ไขนอกเซสชันนี้)

- สคริปต์ถูกเขียนใหม่เป็น 2 ขั้นตอน (OFFO scrape ก่อน แล้ว EPPO scrape ทับ)
  ระหว่างรีวิวพบว่า **การตรวจสอบ "missing products"** ที่เวอร์ชันก่อนหน้าเคยมี
  (เทียบ products ที่ parse ได้กับ `meta_products` แล้ว skip+เตือนถ้าขาด
  เพื่อกัน format spreadsheet เปลี่ยนแล้วข้อมูลหายเงียบ ๆ) **หายไปจากเวอร์ชัน
  ปัจจุบัน** — ตอนนี้ `parse_xlsx()` แค่ข้าม product ที่ resolve ไม่ได้ทีละแถว
  (message คำเตือนเฉย ๆ) แล้วยังคง push วันที่นั้นต่อไปด้วยข้อมูลที่เหลือ
  ถ้าฝั่ง EPPO เปลี่ยนโครงสร้างไฟล์ (เพิ่ม/ลบ/สลับแถว product) อาจทำให้บาง
  product หายไปจากวันนั้นแบบไม่มี error แจ้งเตือนเลย — ยังไม่ได้แก้ (เป็นการ
  ตัดสินใจเชิง design ว่าจะ fail-loud หรือ skip-silent ที่ควรถามเจ้าของสคริปต์
  ก่อน)

## v5.5.1 — 2026-07-07

### index.html

- **รวม EPPO เป็นหมวดเดียวใน series selector** — เดิมแบ่งเป็น "EPPO Diesel" /
  "EPPO Gasoline" / "EPPO Other" 3 กลุ่ม ตอนนี้รวมเป็นกลุ่มเดียวชื่อ "EPPO"
  (ยังจำกัดแค่ Retail/Wholesale + Oil Fund เหมือนเดิม) เอา `EPPO_CATEGORY`
  ที่ใช้แยกหมวดออก

## v5.5 — 2026-07-07

### index.html

- **จำกัด EPPO series ที่เลือกได้ในหน้า chart ทั่วไป** ให้เหลือแค่
  Retail/Wholesale (ราคาขาย) กับ Oil Fund เท่านั้น ซ่อน field breakdown อื่น
  (Ex-Refin, Excise Tax, Municipal Tax, Conservation Fund, VAT, Marketing
  Margin) ออกจาก series picker
  - เดิม `SERIES_GROUPS['EPPO Diesel'/'EPPO Gasoline'/'EPPO Other']` เป็น
    hardcoded doc id ที่ผิด/ไม่ตรงกับ schema จริง (เช่น `EPPO_H_DIESEL_RETAIL`)
    ตอนนี้ generate อัตโนมัติจาก `EPPO_ORDER` + `eppoDocId()` แทน เพื่อให้ id
    ถูกต้องเสมอและไม่ต้องคอย sync มือ
  - เพิ่ม `EPPO_CATEGORY` map เพื่อจัดกลุ่ม Diesel/Gasoline/Other เหมือนเดิม
  - แก้ fallback "Other" optgroup ใน `makeSeriesRow()` ให้ข้าม series ที่ขึ้นต้น
    ด้วย `EPPO_` แต่ไม่อยู่ในกลุ่มที่ generate ไว้ (เดิม field breakdown อื่น ๆ
    จะหลุดไปโผล่ใน optgroup "Other" ของ dropdown ทั่วไปแทน)

## v5.4.1 — 2026-07-07

### index.html

- **เรียงลำดับการ์ด TH Energy ใหม่** — `EPPO_ORDER` เปลี่ยนเป็น Diesel, Gasohol 95,
  Gasohol 91, E20, E85, ULG 95, LPG, FO 1500, FO 600

## v5.4 — 2026-07-07

### index.html

- **MTD/QTD แสดง avg level + %YoY** — เดิม `calcMTD()`/`calcQTD()` คืนแค่ตัวเลข
  average ตอนนี้คืน `{ avg, yoy }` โดย `yoy` เทียบกับค่าเฉลี่ยของ**ช่วงวันที่
  เดียวกัน**ในปีก่อน (ไม่ใช่ทั้งเดือน/ไตรมาสเต็ม ๆ ของปีก่อน) เพื่อเทียบแบบ
  like-for-like:
  - MTD: 1 ต้นเดือนถึงวันนี้ ปีนี้ vs 1 ต้นเดือนถึงวันเดียวกัน (clamp ถ้าเดือน
    สั้นกว่า เช่น ก.พ.) ปีก่อน
  - QTD: 1 ต้นไตรมาสถึงวันนี้ ปีนี้ vs จำนวนวันเท่ากันนับจากต้นไตรมาสปีก่อน
  - การ์ดในหน้า TH Energy แสดงเลข avg เหมือนเดิม และเพิ่มบรรทัด `YoY ±X.X%`
    ด้านล่าง (สีแดง = ราคาขึ้น, สีเขียว = ราคาลง — ตาม convention เดียวกับ RTD)

## v5.3 — 2026-07-07

### index.html

- **เอา print feature ออก** — ลบปุ่ม Print, `@media print` CSS ทั้งหมด, และ
  event listener ที่เกี่ยวกับ `beforeprint`/`afterprint`/`matchMedia('print')`
  (เดิมทำใน v5.2d–v5.2g)
- **เพิ่ม "Export PDF" เฉพาะหน้า TH Energy** — ปุ่มใหม่ `⬇ Export PDF` ที่หัวหน้า
  TH Energy กดแล้วสร้าง PDF ของหน้านั้นทั้งหน้าให้ดาวน์โหลดทันที
  - ใช้ `html2canvas` (แคปหน้าเป็นภาพ) + `jsPDF` (ประกอบเป็น PDF หลายหน้าตาม
    ความสูง) โหลดผ่าน CDN
  - ก่อน export จะขยาย layout เป็น 1 คอลัมน์ + ขยายกราฟเป็นเต็มปี (Jan–Dec)
    ชั่วคราว (ผ่าน class `pdf-export` และ `expandEnergyChartsForExport()`)
    เพื่อให้ label 12 เดือนไม่ชนกันในไฟล์ที่ได้ แล้วคืนค่า layout/zoom กลับ
    หลัง export เสร็จ (สำเร็จหรือ error ก็คืนค่าเสมอ ผ่าน `finally`)
  - ไฟล์ตั้งชื่อ `th-energy-YYYY-MM-DD.pdf`
  - ปุ่มจะ disable + เปลี่ยนข้อความเป็น "กำลังสร้าง PDF…" ระหว่างประมวลผล

## v5.2g — 2026-07-07 (superseded by v5.3 — print feature removed)

### index.html

- **กราฟ TH Energy ตอน print ดูเล็ก/บีบเกินไป** — พอขยายเป็นเต็มปี (v5.2f)
  แล้วยังคง layout 2 คอลัมน์เดิม ทำให้ label เดือนทั้ง 12 เดือนเบียดกันจนอ่าน
  ไม่ออก และพื้นที่กราฟดูเล็กเมื่อเทียบกับพื้นที่ card ที่เหลือ
  - เปลี่ยน `.energy-grid` ตอน print เป็น 1 คอลัมน์ (เต็มความกว้างหน้ากระดาษ)
    แทน 2 คอลัมน์ ให้มีที่พอสำหรับ label 12 เดือน
  - เพิ่ม class `energy-chart-box` ให้ container ของกราฟ และเพิ่มความสูงเป็น
    220px ตอน print (จากเดิม 140px ที่ใช้ตอนแสดงบนจอ)

## v5.2f — 2026-07-07

### index.html

- **TH Energy print แสดงแค่ ~6 เดือนรอบวันล่าสุด ไม่เห็นข้อมูลถึงสิ้นปี** —
  ปกติกราฟ TH Energy zoom เข้าเฉพาะช่วง latest month ±4/+2 เดือนเพื่อโฟกัสข้อมูล
  ล่าสุดตอนใช้งานบนจอ แต่พอ print ผู้ใช้อยากเห็นภาพรวมทั้งปี (Jan–Dec)
  - เก็บ zoom range เดิมไว้ที่ `chart.$zoomRange` ตอนสร้างกราฟ
  - เพิ่ม `expandEnergyChartsForPrint()` / `restoreEnergyChartsZoom()` ขยาย
    แกน x เป็น index เต็มปี (`0` ถึง `labels.length-1`) ตอนเข้าสู่ print
    (`beforeprint` + `matchMedia('print')` change) แล้วคืนค่า zoom เดิม
    หลังพิมพ์เสร็จ (`afterprint`)

## v5.2e — 2026-07-07

### index.html

- **แก้กราฟตกขอบตอน print (โดยเฉพาะหน้า TH Energy)** — สาเหตุคือ Chart.js
  จำ canvas width เป็นค่า px คงที่จากตอน render บนจอ (ซึ่งกว้างกว่าหน้ากระดาษ
  A4) พอสั่งพิมพ์ canvas เลยยืด/ล้นออกนอกขอบกระดาษ
  - เพิ่ม `resizeAllCharts()` เรียก `chart.resize()` ทุก instance (ทั้ง
    `charts` และ `energyCharts`) ตอน `beforeprint`/`afterprint` และตอนออกจาก
    print preview (`matchMedia('print')` change event) เพื่อให้ Chart.js
    คำนวณขนาดใหม่ตามความกว้างหน้ากระดาษจริง
  - เพิ่ม `layout.padding` (right:6, left:2) ในทุก chart config กันเส้นข้อมูล
    ชนขอบ canvas พอดี
  - เพิ่ม CSS สำรอง `canvas { max-width:100% !important }` และ
    `.energy-grid .card { break-inside:avoid; max-width:100% }` กันการล้น/ตัด
    หน้ากระดาษกลาง card

## v5.2d — 2026-07-07

### index.html

- **เพิ่มการรองรับ print** — เพิ่ม `@media print` block ซ่อน nav, ปุ่ม action
  ทั้งหมด (edit/delete/info/timeframe/options), modal และ skeleton ตอนพิมพ์
  เหลือแต่หน้าที่กำลัง active, บังคับพื้นหลังขาว/ตัวหนังสือดำ, กันไม่ให้ card
  ถูกตัดกลางหน้า (`break-inside:avoid`), ขยายความสูงกราฟให้เห็นชัดตอนพิมพ์
  และเพิ่มปุ่ม **🖨 Print** ใน topbar ข้าง ๆ ปุ่ม refresh เพื่อเรียก
  `window.print()` ตรง ๆ

## v5.2c bugfix pass — 2026-07-05

### index.html

1. **MA20/MA50/YoY/MoM ขาดข้อมูลช่วงต้นเมื่อเลือก period สั้น**
   `drawChart()` เดิม cut ข้อมูลตาม period ก่อนแล้วค่อย apply function ทำให้ moving
   average / lookback % ไม่มีข้อมูลย้อนหลังพอ (เช่น เลือก 3M แต่เป็น MA50 จะเหลือ
   จุดข้อมูลไม่กี่จุด หรือว่างเปล่า)
   **แก้:** สลับลำดับเป็น apply function บน full series ก่อน แล้วค่อย cut ตาม period

2. **QTD (quarter-to-date) เพี้ยนไป 1 วันตาม timezone**
   `calcQTD()` เดิมสร้าง `Date` แบบ local time แล้วแปลงผ่าน `.toISOString()` (UTC)
   ทำให้ timezone ที่เร็วกว่า UTC (เช่น ไทย +7) ได้วันเริ่มไตรมาสย้อนไป 1 วัน
   **แก้:** ประกอบ string วันที่จาก local year/month ตรง ๆ ไม่ผ่าน UTC conversion

3. **หารด้วยศูนย์ใน `norm` / `cumret`**
   ถ้าจุดข้อมูลแรกของ series มีค่า 0 จะได้ `Infinity`/`NaN` ไปแสดงบนกราฟ
   **แก้:** หาจุดฐาน (base) เป็นจุดแรกที่ค่าไม่เป็น 0 แทน ถ้าไม่มีเลยให้เป็น `null`
   ทั้งชุด

4. **Dead code ใน `setFont()`**
   มี loop ที่ตั้งใจจะปรับ min-width ของ chart grid ตาม font size แต่ body ของ
   `forEach` return ทันทีโดยไม่ทำอะไร
   **แก้:** ลบ block นี้ทิ้ง (ยังไม่มี logic ที่ใช้งานจริง)

### fetch_eppo.R / fetch_and_push.R

5. **ไม่มีการ dedup/sort จุดข้อมูลก่อน push ขึ้น Firestore**
   `append_series()` / `push_series()` เดิมต่อ `existing_points` กับ `new_points`
   ตรง ๆ โดยไม่เช็ควันที่ซ้ำหรือเรียงลำดับ ถ้ารันสคริปต์ซ้ำในสถานการณ์ที่
   `last_date` ยังไม่ถูกอัพเดท (เช่น รันซ้ำ หรือ partial failure) จุดข้อมูลวันที่
   เดียวกันจะถูกเก็บซ้ำถาวรใน array และไปกระทบค่าเฉลี่ย/กราฟฝั่ง frontend
   **แก้:** เพิ่มฟังก์ชัน `dedup_sort_points()` ใช้ร่วมกันทั้งสองไฟล์ — dedup ตาม
   `date` (เก็บจุดที่มาทีหลังถ้าซ้ำ) แล้ว sort ตามวันที่ ก่อนเขียนกลับ Firestore

## หมายเหตุ

- ยังไม่มี automated test สำหรับ repo นี้ (เป็น static HTML + standalone R
  scripts) แนะนำให้ smoke test ด้วยมือ:
  - เปิดกราฟ, เลือก MA50 + period 3M ดูว่าเส้นครบตั้งแต่ต้นช่วงหรือไม่
  - รัน `fetch_eppo.R` กับ series ที่มีวันที่ซ้ำอยู่แล้ว เพื่อยืนยันว่าไม่เพิ่ม
    จุดซ้ำอีก
