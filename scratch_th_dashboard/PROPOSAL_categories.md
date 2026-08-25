# TH Dashboard — ข้อเสนอจัดหมวด + ปรับชื่อแสดงผล

สถานะ: **ร่าง เสนอก่อน implement** — ยังไม่แก้โค้ดจริง (ยกเว้น 2 จุดเล็กที่
ทำไปแล้วระหว่างคุย: ซ่อน `BOT_SET_BOT` และ `BOT_USDTHB` ออกจาก TH Dashboard
เพราะซ้ำกับ `SET`/`SET_*` และ `USDTHB` — ยืนยันกับ user แล้ว 2026-08-25)

ขอบเขต: เฉพาะ TH Dashboard picker (`thDashEntries()`/`selectThDashCategory()` ใน
index.html) ไม่กระทบ cross-country catalog (`openCatalogModal`) หรือข้อมูลใน
Firestore เลย — เป็นการจัดกลุ่ม/ตั้งชื่อแสดงผลชั้น JS เท่านั้น ใช้ pattern
เดียวกับที่ catalog หลักใช้อยู่แล้ว (supercategory → sub-header → series)

สถานะปัจจุบัน (แก้ไปแล้วก่อนหน้านี้): แยก "Financial Market, Equity & Bonds"
เป็น **Equity** / **Interest Rate & Bonds** และซ่อน `BOT_SET_BOT` แล้ว

---

## 4 หมวดเล็ก — คงเป็น flat list (ไม่ต้องแตก sub-group)

| หมวด | จำนวน | series |
|---|---|---|
| Credit & Financial Stability | 4 | NPL, หนี้ครัวเรือน/GDP, หนี้ต่างประเทศ/GDP, ทุนสำรอง/หนี้ต่างประเทศระยะสั้น |
| Monetary & Exchange rate | 5 | M2, ทุนสำรองระหว่างประเทศ, Forward position, USDTHB (2 ตัว: จาก BOT_USDTHB และ legacy ticker USDTHB) |
| External Trade & BOP | 4 | ส่งออก, นำเข้า, ดุลการค้า, ดุลบัญชีเดินสะพัด |
| Government Finance | 2 | หนี้สาธารณะ, ดุลเงินสด |

`USDTHB` ซ้ำกับ `BOT_USDTHB` จริง — **ซ่อน `BOT_USDTHB` แล้ว** (ทำไปพร้อม
`BOT_SET_BOT` แล้วระหว่างคุย)

---

## หมวดที่ 1: Economic Activity (94 series) → แตกเป็น 5 sub-header

ตรวจ `doc_id` ทุกตัวแล้ว (NESDC เข้ารหัส prefix ตาม National Account
component ไว้ในตัว doc_id เอง — `NESDC_CONS_*` / `NESDC_INVEST_*` /
`NESDC_EXPORTS_*` / `NESDC_IMPORTS_*` / `NESDC_NETEXPORT_*` /
`NESDC_SUPPLY_*`) พบว่าเป็น **NESDC GDP รายไตรมาส** (88 series: 44
component × 2 price type) ปนกับ **BOT sentiment/activity index รายเดือน**
(6 series) — ตัวเลขจริงต่างจากที่ประเมินรอบแรกพอสมควร (ฝั่งรายจ่ายใหญ่กว่าที่
คิด 66 ไม่ใช่ ~30) เลยแนะนำแตกละเอียดขึ้นเป็น 5 กลุ่มแทน 3:

### A. Sentiment & Leading Indicators (BOT) — 6 series
LEI, Business Sentiment Index, Private Consumption Index, Private Investment
Index, จำนวนนักท่องเที่ยวต่างชาติ, อัตราว่างงาน

### B. Consumption Expenditure — Household (NESDC) — 24 series (12 × 2)
`NESDC_CONS_*`: Food and Non-alcoholic Beverages, Alcoholic Beverages Tobacco
& Narcotic, Clothing and Footwear, Housing/Water/Electricity/Gas, Health,
Education, Recreation and Culture, Restaurants and Hotels, Communication,
Furnishings & Household Equipment, Transport, Miscellaneous Goods & Services

### C. Investment — Gross Fixed Capital Formation (NESDC) — 28 series (14 × 2)
`NESDC_INVEST_*`: Construction (แยกย่อย private/public × dwelling/
non-dwelling), Machinery & Equipment (แยกย่อย private/public/transport
equipment)

### D. External Trade in GDP Accounts (NESDC) — 14 series (7 × 2)
`NESDC_EXPORTS_*` + `NESDC_IMPORTS_*` + `NESDC_NETEXPORT_*`: Exports/Imports
of Goods, of Services, of Goods and Services (รวม), Net Exports

### E. GDP by Industry — Value Added (NESDC) — 22 series (11 × 2)
`NESDC_SUPPLY_*`: Agriculture Forestry & Fishing, Manufacturing,
**Construction**, Industrial Sector, Services Sector, Wholesale & Retail
Trade, Financial & Insurance Activities, Real Estate Activities, Transport &
Storage, Information & Communication, Accommodation & Food Service
Activities

**ชื่อแสดงผล**: แต่ละ leaf item ยังต้องมี "Current Prices" / "Chain Volume
Measures" ต่อท้ายเหมือนเดิม (นี่คือ variant จริง ราคาปัจจุบัน vs ปริมาณจริง
ไม่ใช่ตัวซ้ำ)

### ✅ เช็ค Education/Health แล้ว — ไม่ชนกันจริง แต่เจอตัวที่ชนจริงคือ "Construction"

`doc_id` ยืนยันว่า **Education และ Health มีแค่ฝั่ง Consumption (B) เท่านั้น
ไม่มีฝั่ง Industry (E) เลย** — ไม่ใช่ปัญหาจริง ไม่ต้องแก้ชื่อ

แต่เจอตัวที่ชนกันจริง: **"Construction" ปรากฏทั้งใน C (การลงทุนก่อสร้าง)
และ E (มูลค่าเพิ่มภาคก่อสร้าง)** — ชื่อดิบตอนนี้คือ

- C: `"Construction (Gross Fixed Capital Formation)"` — มีวงเล็บกำกับอยู่แล้ว
- E: `"Construction"` — **ไม่มีอะไรกำกับเลย** เสี่ยงสับสนกับตัว C หรือกับ
  Construction sub-item อื่นๆ ใน C (Private/Public/Dwellings) ถ้าเอาไปแสดง
  นอก context เมนู (เช่น chart legend)

**เสนอเปลี่ยนชื่อแสดงผล** (ชั้น JS เท่านั้น ไม่แตะ Firestore):
- E: `"Construction"` → `"Construction (Value Added)"` — ให้ชัดว่าเป็นมูลค่า
  เพิ่มภาคอุตสาหกรรม ไม่ใช่ยอดการลงทุน

---

## หมวดที่ 2: Price Sector (116 series) → แตกเป็น 3 sub-header + EPPO แตกอีกชั้น

ปนกัน 3 แหล่งคนละธรรมชาติ: ราคาน้ำมันปลีก (EPPO), เงินเฟ้อ CPI/PPI (TPSO),
ราคาทอง (GOLDTH)

### A. Fuel Retail Price Breakdown (EPPO) — 100 series → แตกชั้น 3 ตามชนิดน้ำมัน
9 ชนิดน้ำมัน (ULG 95, GASOHOL 91, GASOHOL 95, GASOHOL95 E20, GASOHOL95 E85,
DIESEL, FO 600, FO 1500, LPG) × ~11-12 ส่วนประกอบราคาต่อชนิด — ต้อง sub-header
เป็นชื่อน้ำมันก่อน (ชั้น 3) ไม่งั้น 100 รายการแบนราบเลือกไม่ไหว

**ชื่อ component ที่ยังเป็นโค้ดดิบ ควรแปลเป็นไทยด้วย** (ตอนนี้แสดง
`CONSV_FUND`, `EX_REFIN` ตรงๆ อ่านไม่รู้เรื่องเหมือนปัญหา CTOT ที่แก้ไปก่อน
หน้านี้):

| โค้ดเดิม | ชื่อแสดงผลที่แนะนำ |
|---|---|
| EX_REFIN | ราคา ณ โรงกลั่น |
| EXCISE_TAX | ภาษีสรรพสามิต |
| M_TAX | ภาษีเทศบาล |
| OIL_FUND | กองทุนน้ำมันเชื้อเพลิง |
| CONSV_FUND | กองทุนอนุรักษ์พลังงาน |
| MARKETING_MARGIN | ค่าการตลาด |
| WHOLESALE | ราคาขายส่ง |
| RETAIL | ราคาขายปลีก |
| VAT_WS | VAT (ขายส่ง) |
| VAT_MM | VAT (ค่าการตลาด) |
| DISCOUNT | ส่วนลด |
| EX_RATE | อัตราแลกเปลี่ยนอ้างอิง |

### B. CPI/PPI by Group (TPSO) — 14 series
ชื่อ Thai อ่านง่ายอยู่แล้ว แต่มีคำนำหน้าซ้ำซ้อนกับ sub-header ที่จะขึ้นอยู่
แล้ว ("Price Sector → CPI/PPI by Group (TPSO)") — ตัดคำว่า "TPSO" และ
"CPIG"/"หมวด" (สำหรับ CPI) ที่ซ้ำทิ้ง:

| ชื่อเดิม | ชื่อแนะนำ |
|---|---|
| TPSO CPIG รวมทุกรายการ | CPI รวมทุกรายการ |
| TPSO CPIG หมวดอาหารและเครื่องดื่มไม่มีแอลกอฮอล์ | CPI อาหารและเครื่องดื่มไม่มีแอลกอฮอล์ |
| TPSO CPIG หมวดเครื่องนุ่งห่มและรองเท้า | CPI เครื่องนุ่งห่มและรองเท้า |
| TPSO CPIG หมวดเคหสถาน | CPI เคหสถาน |
| *(อีก 6 หมวด CPI ที่เหลือ — ตัด "TPSO" กับ "หมวด" ออกแบบเดียวกัน)* | |
| TPSO PPI รวมทุกรายการ | PPI รวมทุกรายการ |
| TPSO PPI ผลิตภัณฑ์เกษตรกรรม และการประมง | PPI ผลิตภัณฑ์เกษตรกรรมและการประมง |
| TPSO PPI ผลิตภัณฑ์จากเหมือง | PPI ผลิตภัณฑ์จากเหมือง |
| TPSO PPI ผลิตภัณฑ์อุตสาหกรรม | PPI ผลิตภัณฑ์อุตสาหกรรม |

(regex ง่ายๆ พอ: ตัด `/^TPSO (CPIG|PPI) (หมวด)?/` แล้วแทนด้วย `CPI ` หรือ
`PPI ` ตามกลุ่ม — ไม่ต้อง hardcode ทีละชื่อ)

### C. Gold Price (GOLDTH) — 2 series
ราคาทองคำแท่งรับซื้อ/ขายออก — flat, ไม่ต้องแตก

---

## สรุปโครงสร้างเสนอ (3 ชั้น)

```
Equity                              (flat, 25 series)
Interest Rate & Bonds               (flat, 8 series)
Credit & Financial Stability        (flat, 4 series)
Monetary & Exchange rate            (flat, 4 series — ซ่อน BOT_USDTHB แล้ว)
External Trade & BOP                (flat, 4 series)
Government Finance                  (flat, 2 series)
Economic Activity
 ├─ Sentiment & Leading Indicators (BOT)         flat, 6
 ├─ Consumption Expenditure — Household (NESDC)  flat, 24
 ├─ Investment — GFCF (NESDC)                    flat, 28
 ├─ External Trade in GDP Accounts (NESDC)       flat, 14
 └─ GDP by Industry — Value Added (NESDC)        flat, 22 ("Construction" → "Construction (Value Added)")
Price Sector
 ├─ Fuel Retail Price Breakdown (EPPO)
 │   ├─ ULG 95 / GASOHOL 91 / 95 / E20 / E85 / DIESEL / FO 600 / FO 1500 / LPG
 │   (แต่ละชนิด flat list ~11-12 component แปลไทยแล้ว)
 ├─ CPI/PPI by Group (TPSO)                      flat, 14 (ตัดคำ "TPSO"/"หมวด" ออก)
 └─ Gold Price (GOLDTH)                          flat, 2
```

## Implementation note (สำหรับตอน implement จริง)

- ใช้ pattern เดียวกับ `thDashCategoryFor()` ที่มีอยู่แล้ว — เพิ่ม logic
  แยก sub-header ตาม `doc_id` prefix ตรงๆ ได้เลย ไม่ต้องพึ่ง `meta.dims`
  (NESDC เข้ารหัส component ไว้ใน doc_id อยู่แล้ว: `CONS`/`INVEST`/
  `EXPORTS`/`IMPORTS`/`NETEXPORT`/`SUPPLY`, EPPO เช็คชื่อน้ำมันจาก id,
  TPSO เช็ค `CPIG` vs `PPI`)
- component label ของ EPPO (ตาราง EX_REFIN/EXCISE_TAX/ฯลฯ) + TPSO name trim
  + "Construction (Value Added)" ทำเป็น lookup/regex เล็กๆ ใน JS ทั้งหมด
  (ไม่ต้องแก้ R/backend เพราะเป็นแค่ display label ชั้น UI คล้าย
  `seriesDisplayName()`)
- ✅ verify ครบแล้วทั้ง 2 จุดที่ค้างไว้รอบก่อน — BOT_USDTHB ซ้ำจริง (ซ่อน
  แล้ว), Education/Health ไม่ชนกันจริง (เจอ Construction ชนแทน — มีทางแก้
  ในเอกสารนี้แล้ว) — พร้อม implement เต็มรูปแบบได้เลย
