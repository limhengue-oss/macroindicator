# Changelog — v5.2c bugfix pass

วันที่: 2026-07-05

## index.html

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

## fetch_eppo.R / fetch_and_push.R

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
