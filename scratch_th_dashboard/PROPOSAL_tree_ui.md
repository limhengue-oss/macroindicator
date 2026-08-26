# TH Dashboard — ออกแบบ UI ใหม่เป็น Tree (expand/collapse หลายชั้น)

สถานะ: **ร่าง เสนอก่อน implement** — ยังไม่แก้โค้ด

ตัดสินใจร่วมกับ user แล้ว (2026-08-26):
1. Expand ได้หลายหมวดพร้อมกัน (ไม่ใช่ accordion แบบเปิดอันเดียว)
2. มีช่องค้นหา — พิมพ์แล้ว auto-expand เฉพาะหมวดที่เจอ match
3. Layout เดียว 1 คอลัมน์เต็ม (ทิ้ง 2-column เดิม)
4. Economic Activity → NESDC แยกเป็น Expenditure side / Production side —
   ตัด Deflator ออก (ไม่มี raw data), เรียง 6 ตัวหลักตามที่สั่ง + เพิ่ม
   node "Sub-component (GDP Expenditure)" แยกรายละเอียดออกไปกดดูเพิ่มได้

## โครงสร้างข้อมูล (fixed, มาจาก TH_DASH_STRUCTURE เดิม ปรับ Economic Activity ใหม่ตาม user 2026-08-26)

```
ชั้น 1 (ไม่มีลูก, คลิกโชว์ leaf ตรงๆ): Equity, Interest Rate & Bonds,
  Credit & Financial Stability, Monetary & Exchange rate,
  External Trade & BOP, Government Finance
ชั้น 1 (มีลูก) → ชั้น 2 → leaf:
  Price Sector → CPI/PPI by Group (TPSO) → leaf
  Price Sector → Gold Price (GOLDTH) → leaf
ชั้น 1 → ชั้น 2 → ชั้น 3 → leaf:
  Price Sector → Fuel Retail Price Breakdown (EPPO) → 9 ชนิดน้ำมัน → leaf
  Economic Activity → Expenditure side (NESDC) → [6 ตัวหลัก] → leaf (Real/Nominal)
  Economic Activity → Production side (NESDC) → [11 อุตสาหกรรม] → leaf (Real/Nominal)
ชั้น 1 → ชั้น 2 → ชั้น 3 → ชั้น 4 → leaf (ลึกสุด, ทางเดียวในทั้งต้นไม้):
  Economic Activity → Expenditure side (NESDC) → Sub-component (GDP Expenditure) →
    [24 sub-item] → leaf (Real/Nominal)
```

Economic Activity → Sentiment & Leading Indicators (BOT) ยังเป็นชั้น 2 →
leaf ตรงๆ เหมือนเดิม (6 series รายเดือน ไม่เกี่ยวกับ NESDC)

### Economic Activity → Expenditure side (NESDC) — รายละเอียด

ตรวจ doc_id จริงใน Firestore แล้ว (ดู `NESDC_*` ทั้งหมด) — ระบบมีแค่ 2
variant ต่อ concept: `_NOMINAL` (ราคาปัจจุบัน) กับ `_CVM` (Chain Volume
Measures = ปริมาณจริง/real) **ไม่มี Deflator เป็น series สำเร็จรูป** —
ตัดสินใจร่วมกับ user 2026-08-26: **ตัด Deflator ออกจาก scope นี้ทั้งหมด**
(ต้องคำนวณ Nominal÷Real เอง เป็นฟีเจอร์ cross-series ใหม่ แยกไปทำทีหลัง
ถ้าต้องการ) — เหลือแค่ Real / Nominal เรียงตามลำดับนี้เสมอ

**10 ตัวหลัก** (รอบแก้ 2, ตัดสินใจร่วมกับ user 2026-08-26 — Consumption/
Investment/Export/Import ทุกกลุ่มไม่เอา "total" รวม โชว์แค่ Private/Public
หรือ Goods/Services แยกเลย, ตัด Net Export ทิ้งทั้งหมด, แต่ละตัวเป็น leaf
2 แถว Real/Nominal ไม่ expand ต่อ):

| ลำดับ | ชื่อ (เสนอ) | doc_id concept |
|---|---|---|
| 1 | GDP (Expenditure Approach) | `NESDC_GDP` |
| 2 | Private Consumption Expenditure | `NESDC_CONS_PRIVATE` |
| 3 | Government Consumption Expenditure | `NESDC_CONS_GOVT` |
| 4 | Gross Fixed Capital Formation — Private | `NESDC_INVEST_GFCF_PRIVATE` |
| 5 | Gross Fixed Capital Formation — Public | `NESDC_INVEST_GFCF_PUBLIC` |
| 6 | Exports of Goods | `NESDC_EXPORTS_GOODS` |
| 7 | Exports of Services | `NESDC_EXPORTS_SERVICES` |
| 8 | Imports of Goods | `NESDC_IMPORTS_GOODS` |
| 9 | Imports of Services | `NESDC_IMPORTS_SERVICES` |
| 10 | Change in Inventories (Stock) | `NESDC_INVEST_INVENTORIES` |

ตัดออกจากทุกที่ (ไม่แสดงทั้งในตัวหลักและ sub-component): `NESDC_NETEXPORT`
(ดุลการค้า), `NESDC_INVEST_GFCF` (GFCF รวม), `NESDC_EXPORTS_GS`/
`NESDC_IMPORTS_GS` (Export/Import รวม Goods+Services) — ตาม pattern
เดียวกับ Consumption ที่ไม่เอา total (user ยืนยันแล้วสำหรับ Consumption,
ใช้ pattern เดียวกันกับ Investment/Export/Import ตามที่สั่งเปรียบเทียบไว้)

**Sub-component (GDP Expenditure)** — node expand ชั้น 4 เหลือ **24
concept** (48 series: Real+Nominal ต่อตัว) เพราะ GFCF Private/Public กับ
Export/Import Goods/Services ถูกย้ายขึ้นไปเป็นตัวหลักแล้ว (ไม่ซ้ำ 2 ที่):

- ย่อยของ Private Consumption (COICOP, 12 หมวด): Food and Non-alcoholic
  Beverages, Alcoholic Beverages & Tobacco, Clothing and Footwear, Housing
  Water Electricity Gas, Health, Education, Recreation and Culture,
  Restaurants and Hotels, Communication, Furnishings & Household Equipment,
  Transport, Miscellaneous Goods & Services
- ย่อยของ Investment/GFCF (12 รายการ, เหลือแค่ breakdown ของ Construction/
  Equipment/Machinery — ตัด GFCF Private/Public ออกเพราะย้ายขึ้นตัวหลัก
  แล้ว): Construction (รวม), Construction — Private (รวม/Dwellings/
  Non-Dwellings), Construction — Public (รวม/Dwellings/Non-Dwellings),
  Equipment — Private, Equipment — Public, Machinery and Equipment (รวม),
  Machinery — Other, Machinery — Transport Equipment

(12+12 = 24 concept × 2 variant = 48 series ใน sub-component node — Export/
Import ไม่เหลือ sub-component เลยเพราะ Goods/Services คือระดับย่อยสุดแล้ว)

### Economic Activity → Production side (NESDC) — รายละเอียด

เดิมชื่อ "GDP by Industry — Value Added (NESDC)" — เปลี่ยนชื่อเป็น
"Production side (NESDC)" ให้คู่กับ "Expenditure side" ตามที่ user สั่ง
**ยืนยันแล้ว (2026-08-26)**: ใส่ `NESDC_GDP_PROD` (GDP รวมฝั่ง production
approach) เป็นแถวแรกสุด ก่อน 11 อุตสาหกรรม (Agriculture, Manufacturing,
Construction, Industrial Sector, Services Sector, Wholesale & Retail
Trade, Financial & Insurance, Real Estate, Transport & Storage,
Information & Communication, Accommodation & Food Service) — รวมเป็น 12
รายการ (24 series) ไม่ expand ต่อ (จำนวนไม่เยอะพอจะต้องแตก sub-component
เหมือนฝั่ง Expenditure)

## Interaction

- แต่ละ node ที่มีลูก: คลิกที่ตัว node (ไม่ใช่แค่ลูกศร) toggle expand/collapse —
  ลูกศร ▸/▾ หมุนตาม state
- Node ที่ "ไม่มีลูก" (เช่น Equity, DIESEL) คลิกแล้ว expand โชว์ leaf
  checkbox ตรงนั้นเลย (ไม่ต้องแยกจอ 2 คอลัมน์อีกต่อไป)
- Indent ตาม depth: 16px ต่อชั้น (ชั้น 1 = 0px, ชั้น 2 = 16px, ชั้น 3 = 32px,
  leaf = 48px) — ใช้ padding-left, ไม่ใช้ margin (กัน padding ทับ border)
- Checkbox ของ series ที่เลือกไว้: ยังโชว์ selected count ที่ footer เหมือน
  เดิม ("เลือกไว้ N series") — ไม่เปลี่ยน behavior ส่วนนี้
- Default state ตอนเปิด modal: ทุก node **collapse หมด** (กันแสดง 300+
  รายการทันทีจนกดอะไรไม่ถูก) ยกเว้นถ้ามี series ที่เลือกไว้แล้ว (edit mode)
  ให้ auto-expand เฉพาะ path ที่นำไปสู่ series ที่เลือกไว้

## Search

- Input box บนสุดของ tree, placeholder "ค้นหา series..."
- Debounce ~150ms พอ (list ไม่ใหญ่มาก ~300 รายการ ไม่ต้อง virtualize)
- Match แบบ substring, case-insensitive, เทียบกับ:
  - ชื่อ leaf (`thDashSeriesLabel(e)` ที่แปลแล้ว ไม่ใช่ raw name)
  - ชื่อ node ทุกชั้นระหว่างทาง (เช่น พิมพ์ "eppo" เจอทั้งหมวด แม้ leaf
    component ไม่มีคำว่า eppo อยู่เลย)
- เมื่อมีคำค้น: auto-expand ทุก path ที่มี match, **ซ่อน node ที่ไม่มี
  match เลยทั้งสายทิ้งไปเลย** (ไม่ใช่แค่เอา match ไว้บนสุด) — list จะสั้นลง
  มาก ตรงตามที่ user บอกไว้ว่า "auto-expand เฉพาะหมวดที่เจอ"
- เคลียร์ค้นหา → กลับไป state collapse-all (หรือ state ก่อนพิมพ์ค้นหาถ้ามี)

## Mockup

```
┌─ TH Economic Dashboard ─────────────────────────────┐
│ 🔍 [________________________]                       │
│                                                      │
│ ▸ Equity                                            │
│ ▸ Interest Rate & Bonds                             │
│ ▸ Credit & Financial Stability                      │
│ ▸ Monetary & Exchange rate                          │
│ ▸ External Trade & BOP                              │
│ ▸ Government Finance                                │
│ ▾ Economic Activity                                 │
│     ▸ Sentiment & Leading Indicators (BOT)          │
│     ▾ Expenditure side (NESDC)                      │
│         ☐ GDP (Expenditure Approach), Real          │
│         ☑ GDP (Expenditure Approach), Nominal       │
│         ☐ Private Consumption Expenditure, Real     │
│         ☐ Government Consumption Expenditure, Real  │
│         ☐ Gross Fixed Capital Formation — Private.. │
│         ☐ ... (GFCF Public/Export/Import Gds&Svcs)  │
│         ☐ Change in Inventories (Stock), Real       │
│         ▸ Sub-component (GDP Expenditure)           │
│     ▸ Production side (NESDC)                       │
│ ▾ Price Sector                                      │
│     ▾ Fuel Retail Price Breakdown (EPPO)            │
│         ▾ DIESEL                                    │
│             ☐ ราคา ณ โรงกลั่น                        │
│             ☑ ภาษีสรรพสามิต                          │
│         ▸ GASOHOL 91                                │
│     ▸ CPI/PPI by Group (TPSO)                       │
│                                                      │
│ ✓ เลือกไว้ 2 series                                  │
│                              [Back]         [Next]  │
└──────────────────────────────────────────────────────┘
```

## แนวทาง implement (สรุปสั้นๆ ไว้ก่อน ยังไม่ลงมือ)

- ทิ้ง `th-dash-col-category`/`th-dash-col-series` (2 div) → เหลือ div เดียว
  `th-dash-tree` + search input `th-dash-search`
- เก็บ expand state เป็น `Set` ของ node key ที่เปิดอยู่ (`thDashExpanded`)
  แทนที่ `thDashState.category` เดี่ยวแบบเดิม
- Render แบบ recursive: วน `TH_DASH_STRUCTURE` (ปรับ shape เป็น nested
  tree object แทน flat header/items เดิม) → ใส่ indent ตาม depth →
  checkbox เฉพาะ leaf node
- search filter คำนวณ "node ไหนควรโชว์" ก่อน render (bottom-up: leaf match
  → parent ต้องโชว์ด้วย) แล้ว auto-add เข้า `thDashExpanded` ชั่วคราว
- CSS: reuse `.cat-item`/`.cat-item.leaf` เดิมเกือบทั้งหมด เปลี่ยนแค่
  indent + ลูกศร expand/collapse (ใช้ pattern เดียวกับ chevron ที่มีอยู่
  แล้วใน `catalogSuperCategoryFor`/`▴`/`▾` ของ TH Energy price breakdown)
- ไม่กระทบ cross-country catalog (`openCatalogModal`) เลย — จำกัดแก้แค่
  TH Dashboard เหมือนรอบที่แล้ว
