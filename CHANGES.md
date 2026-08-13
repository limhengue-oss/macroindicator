# Changelog

## v5.17 — 2026-08-12

### fetch_imf_cpi.R — เลือก CPI vs HICP ต่อประเทศ

- **พบว่า fetch เดิม hardcode `INDEX_TYPE=CPI` เสมอ ไม่เคยดึง HICP เลย** —
  ตรวจพบตอนทบทวนเทียบกับการวิเคราะห์ความสมบูรณ์ข้อมูลแบบละเอียดที่ทำแยกไว้
  ในโปรเจกต์ GlobalCPIDBV2 (`IMF_analysis/process.md`) ซึ่งพบว่า 32 ประเทศ
  (ส่วนใหญ่ EU/EFTA) รายงานทั้ง CPI และ HICP โดย HICP สมบูรณ์กว่าใน 27
  ประเทศ — ของเดิมเลือก CPI ตายตัวจึงไม่ได้ข้อมูลที่สมบูรณ์ที่สุดสำหรับ
  ประเทศกลุ่มนี้
- **แก้**: ดึง wildcard ทั้ง `INDEX_TYPE=CPI` และ `HICP` (2 requests แทน 1)
  แล้วเลือกต่อประเทศตาม `data/imf_index_type.csv` (ไฟล์ใหม่ — แปลงจาก
  `chosen_index_type.csv` ของ GlobalCPIDBV2 ด้วย IMF CL_COUNTRY codelist,
  ISO3 ↔ formal name, commit ไว้ใน repo นี้เลยเพราะ GitHub Actions มองไม่
  เห็นข้าม repo) ประเทศไหนไม่อยู่ในลิสต์ fallback เป็น CPI
- **ไม่ splice SRP_IX** (ยืดประวัติย้อนหลังก่อนปี 2014) ตามที่
  GlobalCPIDBV2 ทำ — งานนั้นเป็น one-time historical backfill ที่ทำแยกไว้
  แล้วในโปรเจกต์นั้น สคริปต์นี้สนใจแค่การอัพเดทไปข้างหน้า (native IX พอ
  เพราะไม่มีช่องว่างต้องเติมสำหรับข้อมูลปัจจุบัน/อนาคต)
- ตรวจสอบด้วยการรันจริง + เทียบค่ากับ live API: Austria (`AUT`) ที่เลือก
  HICP ตามลิสต์ ได้ค่า headline ล่าสุด 143.16 ตรงกับ `AUT.HICP._T.IX.M`
  เป๊ะ (ต่างจาก `AUT.CPI._T.IX.M` = 143.51) — ยืนยันว่า filter logic ทำงาน
  ถูกจริง ไม่ใช่แค่ parse ผ่าน — series รวมเพิ่มจาก 1,747 เป็น **1,932**
  (191 ประเทศเท่าเดิม เพราะประเทศที่ชนะ HICP ก็รายงาน CPI ควบคู่อยู่แล้ว
  ไม่มีประเทศไหนได้ข้อมูลเพิ่มจากศูนย์ — ได้ "คุณภาพ" ไม่ใช่ "ปริมาณ")

## v5.16 — 2026-08-10

### เพิ่มหน้า GlobalCPI + fetch_imf_cpi.R

- **หน้าใหม่ "GlobalCPI"** — เปรียบเทียบเงินเฟ้อ (%YoY) รายประเทศจาก IMF CPI
  จัดเป็น 4 การ์ด (Advanced Economies, Emerging Asia Excl. ASEAN, ASEAN,
  Latin America) 1 เส้น = 1 ประเทศ เส้นเทาโดย default, มีปุ่ม "Highlight ▾"
  ต่อการ์ดให้ติ๊กเลือกประเทศที่อยากเน้นแยกสี, เลือก window (1Y/3Y/10Y/30Y)
  และหมวด COICOP (headline + 12 หมวด) ได้จาก dropdown ร่วมทั้ง 4 การ์ด
- **`fetch_imf_cpi.R`** (สคริปต์ใหม่) — ดึง CPI index ดิบรายเดือนจาก IMF STA
  CPI(5.0.0) ทุกประเทศที่ IMF เผยแพร่จริง (~180 ประเทศ, ยืนยันด้วยการรันจริง
  ไม่ใช่แค่เดา) x หัวข้อรวม + 12 หมวด COICOP — พอร์ตวิธี wildcard bulk-fetch
  (1 request ได้ทุกประเทศ) มาจากโปรเจกต์ GlobalCPIDB ที่ live-test ไว้แล้ว
  ตัดเหลือเฉพาะรายเดือน (ไม่ดึง Quarterly fallback) เพราะหน้า GlobalCPI
  ต้องการแกนเวลาเดียวกันทุกเส้น
  - workflow ใหม่ `.github/workflows/fetch-imf-cpi.yml` (`workflow_dispatch`,
    `dry_run` default true — series เยอะ ควรเช็ค coverage ก่อน push จริง)
- **แยกข้อมูล GlobalCPI ออกจาก series ที่หน้าอื่นเข้าถึงได้โดยเจตนา** —
  `fetchRest()` (ที่หน้า Dashboard/catalog/custom chart อาศัยอ่าน) ข้าม doc
  `IMF_{ISO3}_CPI_{00..12}` ไปเลย ไม่เก็บเข้า `SERIES` กลาง; เพิ่ม
  `fetchGlobalCPI()` เป็น query แยกต่างหาก เก็บลง `GLOBALCPI_SERIES` คนละ
  object ที่มีแค่หน้า GlobalCPI อ่านได้ — โหลดแบบ lazy ตอนกดเข้าหน้าครั้งแรก
  เท่านั้น ไม่ผูกกับ Phase 1/2 ของ `loadData()`

### รวมโค้ด R ที่ซ้ำกันของ fetch_*.R เป็น R/firestore.R

- `get_access_token()` / `push_series()` / `dedup_sort_points()` / `%||%`
  copy-paste เหมือนกันเกือบทุกตัวอักษรอยู่ 9 ไฟล์ (`fetch_and_push.R`,
  `fetch_bis.R`, `fetch_bot.R`, `fetch_goldth.R`, `fetch_imf.R`,
  `fetch_imf_cpi.R`, `fetch_nesdc.R`, `fetch_thaibma.R`, `fetch_tpso.R`) —
  ย้ายมารวมที่ `R/firestore.R` ไฟล์เดียว (~665 บรรทัดที่ซ้ำถูกลบออก) แต่ละ
  สคริปต์เหลือแค่ `source("R/firestore.R")`
  - `push_series()` มี 2 พฤติกรรมจริง (ไม่ใช่แค่ copy เฉยๆ): full-replace
    กับ incremental-merge (`is_incremental` param) — รวมเป็นฟังก์ชันเดียว
    ที่รองรับทั้งคู่แทนบังคับให้เหมือนกัน; เพิ่ม `quiet` param ให้
    `fetch_imf_cpi.R` ใช้ (push ~1,500+ series ต่อรอบ ไม่อยาก spam log ทีละ doc)
  - ตรวจสอบด้วยการรัน `fetch_imf.R` และ `fetch_imf_cpi.R` จริงผ่าน
    shared module แบบ dry-run จบ end-to-end ไม่ใช่แค่ตรวจ syntax

### จัดโฟลเดอร์: scripts/oneoff/

- ย้าย `push_oilfund_backfill.R` → `scripts/oneoff/push_oilfund_backfill.R`
  (เป็น one-off — งานรันไปแล้วครั้งหนึ่ง เก็บไว้เผื่อต้อง re-seed ข้อมูล
  กรณี Firestore หาย ไม่ใช่ส่วนหนึ่งของ pipeline ปกติ) แก้
  `.github/workflows/backfill-oilfund.yml` ให้ชี้ path ใหม่
  - `push_meta_only.R` **ไม่ย้าย** — ยังเป็นแหล่ง metadata เดียวของ series
    EPPO ทั้งหมด (`fetch_eppo.R` ตั้งใจไม่แตะ field `meta` เลย) ยังต้องรันซ้ำ
    ทุกครั้งที่มีสินค้า EPPO ใหม่ ไม่ใช่ one-off

## v5.15 — 2026-07-10 (bugfix)

### fetch_and_push.R

- **สาเหตุที่ metadata ไม่เสถียร (แสดงแค่ "Updated" หายไปเรื่อย ๆ)** —
  `push_series()` เขียนเข้า Firestore ด้วย `PATCH` แบบไม่มี `updateMask` เลย
  ซึ่งตาม semantics ของ Firestore REST API ถ้า PATCH โดยไม่ระบุ updateMask
  จะ**ทับทั้ง document** ด้วย field ที่ส่งไปเท่านั้น field เดิมที่ไม่ได้ส่งมา
  ก็จะถูกลบทิ้งไปเลย
  - `meta` (fullName/unit/source ฯลฯ) จะถูกดึงมาส่งด้วยก็ตอน **backfill ครั้ง
    แรกของ series นั้นเท่านั้น** (`if (!is_incremental) fetch_meta_yf(...)`)
    ส่วนการรันแบบ **incremental** ทุกครั้งถัดไป (ซึ่งคือการรันปกติเกือบทั้งหมด
    เช่นรันทุกวันผ่าน GitHub Actions) จะส่ง `meta = NULL` — พอ PATCH ทับทั้ง
    document โดยไม่มี field `meta` อยู่ใน body และไม่มี updateMask ป้องกันไว้
    **field `meta` ที่เคยตั้งไว้ (ทั้งจาก backfill ครั้งแรกและจาก
    `push_meta_only.R` ที่รันแยกทีหลัง) จะถูกลบทิ้งทันทีในรอบ fetch ถัดไป**
    เหลือแค่ `name`/`updated`/`data` — ตรงกับอาการที่เห็น (metadata list
    เหลือแค่วันอัพเดท ไม่มี Full name/Unit/Source)
  - ปัญหานี้เกิดกับ**ทุก series ใน `CATALOG`** ของ `fetch_and_push.R` (SPX,
    Mag7, FX, Commodities, US/EU Macro ฯลฯ) ไม่ใช่แค่ EPPO — และเกิดซ้ำทุก
    รอบที่สคริปต์รัน (ไม่ใช่ครั้งเดียว) ทำให้ดูเหมือน "ไม่เสถียร"
  - `fetch_eppo.R` ไม่มีปัญหานี้อยู่แล้ว เพราะมี
    `updateMask.fieldPaths=c("name","updated","data")` ป้องกันไว้ตั้งแต่ก่อน
    หน้านี้ (ไม่รู้ว่าใครแก้ไว้ตั้งแต่เมื่อไหร่ แต่ pattern ถูกแล้ว)
  **แก้:** เพิ่ม `updateMask.fieldPaths` ให้ `push_series()` แบบไดนามิก —
  ปกติจำกัดแค่ `name/updated/data`, แต่ถ้ารอบนั้นมี `meta` ส่งมาด้วย (backfill
  ครั้งแรก) จะรวม `meta` เข้า mask ด้วย ป้องกันไม่ให้ PATCH ทับ field ที่ไม่ได้
  ตั้งใจจะแก้
  - **ต้องทำต่อ**: รัน `push_meta_only.R` (workflow "Push Series Metadata")
    ใหม่อีกครั้งหลัง deploy fix นี้ เพื่อเติม metadata ที่หายไปกลับเข้า
    Firestore — ครั้งนี้จะไม่ถูกลบซ้ำแล้วเพราะ `fetch_and_push.R` เขียนแบบ
    scoped ไม่ทับทั้ง document อีกต่อไป

## v5.14 — 2026-07-07

### index.html

- **Format วันที่ช่อง "ล่าสุด" เปลี่ยนจาก MM-DD เป็น D-Mon** (เช่น `07-08` →
  `8-Jul`) — เพิ่มฟังก์ชัน `fmtDMon(dateStr, withYear)` ใช้ร่วมกันทั้งการ์ด
  product ปกติและการ์ด Oil Fund Status
- **วันที่ข้อมูลล่าสุดข้าง legend เปลี่ยนเป็น D-Mon-YYYY** (เช่น
  `8-Jul-2026`) — เรียก `fmtDMon(latestPriceDate, true)`
- **Shared legend จัด center ของหน้าแทนการ indent ชิดซ้าย** — เอา
  `padding-left:12px` ที่เพิ่มไว้ก่อนหน้า (v5.13) ออก เปลี่ยนเป็น
  `justify-content:center` บน `#energy-shared-legend`

## v5.13 — 2026-07-07

### index.html

- **Legend "ปีนี้/ปีก่อน" ไม่ได้ขนาด/bold ตามที่ตั้งไว้จริง** — v5.12 เพิ่ม
  `font-size:0.88em;font-weight:600` ที่ container `#energy-shared-legend`
  แต่ `.li` class (ใช้ครอบ "ปีนี้"/"ปีก่อน") มี `font-size:0.72em` ของตัวเอง
  ซึ่ง override ค่าที่ inherit มาจาก parent (font-size ของ element ตัวเองชนะ
  เสมอไม่ว่า parent จะประกาศไว้เท่าไหร่) ทำให้สองคำนี้ยังเป็นขนาดเดิม ไม่โต
  ตามที่ขอ — **แก้:** เพิ่ม inline `font-size:1em;font-weight:600` ที่ตัว
  `.li` div ทั้งสองตัวโดยตรง (1em = สืบต่อขนาดจาก parent 0.88em พอดี)
- **Indent legend ให้ตรงกับแนวข้อความ DIESEL** — เพิ่ม `padding-left:12px`
  ให้ `#energy-shared-legend` (16px จาก `.page` + 12px นี้ = 28px ตรงกับ
  16px ของ `.energy-hero` + 12px ของ `.ch` ที่ครอบชื่อ "DIESEL")

## v5.12 — 2026-07-07

### index.html

- **Oil Fund Status "ล่าสุด" ตัดปีออก** — เปลี่ยนจาก `ofLast.x.slice(0,10)`
  (YYYY-MM-DD) เป็น `ofLast.x.slice(5,10)` (MM-DD) ให้ตรงกับ format ที่การ์ด
  product อื่นใช้อยู่แล้ว
- **เพิ่มวันที่ข้อมูลราคาน้ำมันล่าสุดข้าง shared legend** — เก็บ
  `latestPriceDate` (ค่าสูงสุดของ `last.x` ที่เจอระหว่างวนลูป `EPPO_ORDER`)
  แล้วแสดงเป็น MM-DD ใน span `#energy-latest-date` ต่อจาก legend "ปีนี้/ปีก่อน"
- **ขยาย font legend + วันที่ล่าสุด +10% และ bold** — `#energy-shared-legend`
  เปลี่ยนจาก `font-size:0.8em` เป็น `0.88em` (+10%) พร้อมเพิ่ม
  `font-weight:600`

## v5.11 — 2026-07-07

### index.html

- **Oil Fund Status chart: สีเปลี่ยนตามเครื่องหมาย** — ใช้ Chart.js `segment`
  option แทนสีคงที่เดิม (`#4d9fff` ฟ้าล้วน):
  - ติดลบ (ฐานะกองทุนขาดดุล) → เส้นสีแดง (`var(--dn)`) + พื้นที่สีชมพู
    (`rgba(255,99,132,0.22)`)
  - บวก (ฐานะกองทุนเกินดุล) → เส้นสีเขียว (`var(--up)`) + พื้นที่สีเขียวอ่อน
    (`rgba(52,199,89,0.18)`)
  - ใช้ตรรกะเดียวกันกับเส้น "คาดการณ์" (เฉพาะสีเส้น เส้นยังเป็นเส้นประเหมือนเดิม)
- **แก้เงาการ์ดหายไปในธีมมืด** — `--card-shadow` เดิมเป็น
  `rgba(0,0,0,0.45)` (สีดำ) วางบนพื้นหลังหน้าเว็บที่เป็นสีดำสนิท
  (`--bg:#000000`) เลยกลืนไปกับพื้นหลังจนมองไม่เห็นเงาเลย ไม่ว่าจะปรับ
  blur/opacity แค่ไหนก็ตาม (สีเดียวกันบนสีเดียวกัน blend กันแล้วก็ยังเป็นสีเดิม)
  **แก้:** เพิ่ม shadow layer ที่ 2 เป็นเส้นขอบจาง ๆ สีขาว 1px
  (`rgba(255,255,255,0.06)`) ให้เห็นขอบการ์ดชัดขึ้นแม้บนพื้นหลังสีดำ

## v5.10 — 2026-07-07

### index.html

- **Export PDF เพิ่มการ์ด Oil Fund Status** — เดิม `PDF_EXPORT_BASES` มีแค่
  `['DIESEL', 'GASOHOL 95']` เพิ่ม `'OIL_FUND_STATUS'` เข้าไปด้วย พร้อมตั้ง
  `ofBox.dataset.base = 'OIL_FUND_STATUS'` ให้การ์ด Oil Fund Status (เดิมไม่มี
  `data-base` เลยไม่ถูกนับเป็น target มาก่อน)
- **ปรับ layout hero ตอน export เป็น 3 คอลัมน์** (จากเดิม 2 คอลัมน์ที่ออกแบบ
  ไว้ตอนมีแค่ 2 การ์ด) — `#energy-hero.pdf-export .energy-hero-grid` เปลี่ยน
  จาก `1fr 1fr` เป็น `repeat(3,1fr)` ให้ Diesel/Gasohol95/Oil Fund Status
  เรียงแถวเดียวกันพอดีในหน้า A4 แนวนอน

## v5.9.3 — 2026-07-07

### index.html

- **แก้ label บรรทัดแรกของโครงสร้างราคา** จาก "Ex-Refinery (หน้าโรงกลั่น)"
  เป็น "ราคาหน้าโรงกลั่น"

## v5.9.2 — 2026-07-07

### index.html

- **โครงสร้างราคาเพิ่มบรรทัดแรก/สุดท้ายกลับมา** — เดิม v5.8 ย่อเหลือแค่ 4
  component (Tax+Cons.Fund, Marketing Margin, VAT, Oil Fund) ตอนนี้เพิ่ม:
  - บรรทัดแรก: **Ex-Refinery (หน้าโรงกลั่น)** — ดึงจาก field `EX_REFIN` ตรง ๆ
  - บรรทัดสุดท้าย: **Retail Price (หน้าปั๊ม)** หรือ **Wholesale Price
    (หน้าคลัง)** ตามแต่ละสินค้า (ใช้ field เดียวกับที่การ์ดใช้แสดง "ล่าสุด"
    ด้านบน — RETAIL สำหรับส่วนใหญ่, WHOLESALE สำหรับ FO 1500/FO 600)
  - ทั้งสองบรรทัดนี้ตัวหนา (bold) แยกจาก 4 component กลาง เพื่อให้เห็นเป็น
    "จุดเริ่ม/จุดจบ" ของโครงสร้างราคาชัดเจน
  - รีแฟกเตอร์ logic สร้างแถวตารางเป็นฟังก์ชันร่วม `makeBreakdownRow()` ใช้ซ้ำ
    ได้ทั้ง Ex-Refin, 4 component, และ Retail/Wholesale
- **เอาพื้นหลังสีฟ้าของการ์ดออก กลับเป็นสีเดิม** — ลบ `--card-bg` (ที่เพิ่มใน
  v5.9) ออก `.card` ใช้ `background:var(--bg2)` แบบเดิมก่อนแก้ — ยังคง
  `--card-shadow` และ spacing/border-radius ที่ปรับไว้ก่อนหน้า

## v5.9.1 — 2026-07-07

### index.html

- **เอาเงาออกจากการ์ดย่อยแต่ละ chart ในหมวด hero (Diesel/Gasohol95/Oil Fund)**
  — `.energy-hero-grid > .card` เพิ่ม `box-shadow:none` (เดิมพื้นหลังโปร่งใส
  แต่ยังมีเงาติดมาจาก `.card` ทำให้ดูเหมือนเงาลอยไม่มีกล่อง)
- **ย้ายเงาไปไว้ที่ card แม่ (`.energy-hero`) แทน** — เพิ่ม
  `box-shadow:var(--card-shadow)` ให้ container ใหญ่ที่ครอบทั้ง 3 chart
- **เอาเส้นขอบสีน้ำเงินของ `.energy-hero` ออก** — เปลี่ยนจาก
  `border:1px solid var(--blue)` เป็น `border:1px solid var(--border)`
  (สีเดียวกับการ์ดทั่วไป) พร้อมปรับ `border-radius` เป็น 8px ให้เข้าชุดกับ
  การ์ดอื่น
- **เพิ่มช่องไฟด้านบน/ล่างของ chart ในการ์ด** — padding ของ div ที่ครอบ
  `.energy-chart-box` จาก `6px 12px 10px` เป็น `14px 12px 16px` (ทั้งการ์ด
  product ปกติและการ์ด Oil Fund Status)

## v5.9 — 2026-07-07

### index.html

- **Card visual refresh** — เพิ่ม `--card-bg`/`--card-shadow` (theme-aware, ทั้ง
  dark และ light) แล้วให้ `.card` ใช้แทน `background:var(--bg2)` เดิม:
  - พื้นหลังการ์ดเป็นสีฟ้าอ่อน ๆ (`#10192b` โทนมืดฟ้าเข้มใน dark theme,
    `#eef6ff` ฟ้าอ่อนใน light theme) แทนสีเทาเรียบเดิม
  - เพิ่ม `box-shadow` จาง ๆ ให้การ์ดดูลอยเด่นขึ้นจากพื้นหลัง
  - เพิ่ม `border-radius` จาก 4px → 8px ให้ดูนุ่มนวลขึ้นรับกับเงา
  - เพิ่ม gap ระหว่างการ์ด: `.energy-grid` 16px→22px, `.chart-grid` 10px→16px
    ให้มีช่องไฟ/breathing room รอบขอบการ์ดมากขึ้น

## v5.8 — 2026-07-07

### index.html

- **โครงสร้างราคาย่อจากทุก field เหลือ 4 component** — `BREAKDOWN_FIELDS`
  เปลี่ยนจาก list field ดิบ (Ex-Refinery, Excise Tax, Municipal Tax, Oil Fund,
  Conservation Fund, Wholesale, VAT(WS), Marketing Margin, VAT(MM), Retail)
  เป็น 4 กลุ่ม:
  1. **Tax + Cons. Fund** = Excise Tax + Municipal Tax + Conservation Fund
  2. **Marketing Margin**
  3. **VAT** = VAT(WS) + VAT(MM)
  4. **Oil Fund**
  - `getBreakdownAtDate()` รวมค่า sub-field ตาม `keys` ของแต่ละกลุ่มให้แล้ว
    (ถ้าทุก sub-field เป็น null จะได้ `null`, ถ้ามีบางตัว null จะรวมเฉพาะที่
    มีค่า)
  - เอา row "Retail"/"Wholesale" (total) ออก เพราะไม่ใช่ 1 ใน 4 component ที่
    ขอ — ตัวเลข Retail/Wholesale ยังดูได้จากช่อง "ล่าสุด" ด้านบนการ์ดตามปกติ
- **Diesel/Gasohol 95 เปิดโครงสร้างราคาไว้ default + ผูก state กัน** —
  `BREAKDOWN_DEFAULT_OPEN_BASES` กำหนดให้ 2 การ์ดนี้ render เป็น expand ตั้งแต่
  แรก, `toggleBreakdown()` เช็คว่า id ที่กดอยู่ใน `BREAKDOWN_LINKED_IDS`
  (ของ Diesel/Gasohol 95) ไหม ถ้าใช่จะ toggle ทั้งคู่พร้อมกันเสมอ (เปิดพร้อมกัน
  ปิดพร้อมกัน ไม่ว่าจะกดจากการ์ดไหน)

## v5.7.2 — 2026-07-07

### index.html

- **TH Energy chart zoom พังเมื่อเดือนล่าสุดอยู่ใกล้ต้น/ท้ายปี** — เดิม
  `zoomStart`/`zoomEnd` คำนวณด้วย modulo (`% 12`) ให้ wrap ข้ามปีได้ (เช่น
  เดือนล่าสุด = มี.ค. → zoomStart wrap ไปเป็น พ.ย.) แต่ `yearLabels` เป็น
  array ม.ค.–ธ.ค. **ปีเดียว** ไม่มีแนวคิดข้ามปี ผลคือ index ของเดือนที่ wrap
  ไปอยู่ท้าย array กลายเป็น `zoomMinIdx > zoomMaxIdx` (min มากกว่า max) ซึ่ง
  เป็นค่าที่กลับด้านกัน ทำให้ Chart.js แสดงผลผิดเพี้ยน — เกิดกับเดือนล่าสุดใน
  ช่วง ม.ค.–เม.ย. (wrap ถอยหลัง) และ พ.ย.–ธ.ค. (wrap ไปข้างหน้า)
  **แก้:** เปลี่ยนจาก modulo wrap เป็น clamp ให้อยู่ในช่วง 1–12 เสมอ
  (`Math.max(1, latestMon-4)` / `Math.min(12, latestMon+2)`) — เดือนล่าสุด
  ใกล้ขอบปีจะได้ช่วงซูมสั้นกว่าปกติ (ไม่ครบ 6 เดือน) แทนที่จะ wrap ข้ามปีแล้ว
  ได้ range ที่กลับด้าน

## v5.7.1 — 2026-07-07

### index.html

- **Chart ตกขอบขวาบางหน้าจอ** — Chart.js คำนวณขนาด canvas ครั้งเดียวตอน
  สร้างกราฟ (ตอน `renderEnergyPage()`/`drawChart()`) แล้วไม่มีอะไรบังคับให้
  คำนวณใหม่ถ้า viewport เปลี่ยนขนาดหลังจากนั้น (ย่อ-ขยาย browser, หมุนจอ,
  เปิดจากหน้าจอ/ความละเอียดอื่น) ทำให้ canvas ค้างความกว้างเดิมแล้วล้นออกนอก
  การ์ด/หน้าจอ
  - เพิ่ม `window.addEventListener('resize', ...)` (debounce 150ms) เรียก
    `chart.resize()` ทั้ง `charts` (หน้า chart ทั่วไป) และ `energyCharts`
    (TH Energy) ทุกครั้งที่ resize
  - เพิ่ม CSS safeguard: `canvas { max-width:100% }` และ
    `html { overflow-x:hidden }` กันไม่ให้ canvas หรือ layout ดันความกว้าง
    ของทั้งหน้าเกิน viewport ไม่ว่าจอจะขนาดไหน

## v5.7 — 2026-07-07

### index.html

- **Export PDF จำกัดเหลือแค่ Diesel + Gasohol 95** — เพิ่ม `PDF_EXPORT_BASES`
  และ `box.dataset.base` (ตั้งตอนสร้างการ์ดใน `renderEnergyPage()`) เพื่อระบุ
  ว่าการ์ดไหนคือสินค้าอะไร ตอน export จะซ่อนการ์ดอื่นที่ไม่อยู่ใน list ไว้
  ชั่วคราว (`display:none`) แล้วคืนกลับหลัง export เสร็จ
- **บังคับเปิด "โครงสร้างราคา" (breakdown)** ของทั้ง 2 การ์ดก่อน capture — เรียก
  `toggleBreakdown()` ให้เปิดถ้ายังปิดอยู่ แล้ว toggle ปิดกลับหลัง export
  (ถ้าตอนกดปุ่มมันเปิดอยู่แล้วจะไม่ไปยุ่งกับมัน)
- **Layout เปลี่ยนเป็น A4 แนวนอน (landscape)** — `new jsPDF('l','mm','a4')`
  แทน `'p'` เดิม, `#energy-boxes.pdf-export` เปลี่ยนจาก 1 คอลัมน์เป็น 2
  คอลัมน์ (`grid-template-columns:1fr 1fr`) ให้ Diesel กับ Gasohol 95 อยู่
  คู่กันในหน้าเดียว

## v5.6 — 2026-07-07

### index.html

- **3M/6M: ไม่แสดง label เดือนที่ข้อมูลเริ่มหลังวันที่ 4** — ถ้าวันแรกที่มี
  ข้อมูลของเดือนนั้น (`firstDayIdx`) เป็นวันที่ > 4 (เช่น series เริ่มมีข้อมูล
  กลางเดือน) จะไม่เพิ่มเข้า major set เลย (ไม่มีทั้ง grid เข้มและ label)
- **6M: format label เอาปีออก** — เดิมแสดง `1-Jan-2026` ตอนนี้แสดง `1-Jan`
  เหมือน 3M

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
