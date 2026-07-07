# Changelog

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
