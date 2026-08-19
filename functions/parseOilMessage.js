// parseOilMessage.js
// ดึงเฉพาะ 3 ค่าที่ต้องการจากข้อความ broadcast ของ PEIT:
//   - วันที่ราคา (จากบรรทัด "($/B) 18 August 2026:")
//   - ULG 95 (S'pore) -> ULG95_SG
//   - GO 0.001%S      -> DIESEL_SG
//
// ตัวอย่างข้อความ:
//   🌏World Oil Price
//   ($/B) 18 August 2026:
//   Dubai  92.72 / +2.56
//   Dt Brent  90.29 / +2.44
//   WTI  84.94 / +0.44
//   ULG 95 (S'pore)  118.44 / +2.89
//   GO 0.001%S  165.22 / +5.46
//   ...

const MONTH_TH = {
  January: "01", February: "02", March: "03", April: "04",
  May: "05", June: "06", July: "07", August: "08",
  September: "09", October: "10", November: "11", December: "12",
};

function toIsoDate(day, monthName, year) {
  const mm = MONTH_TH[monthName];
  if (!mm) return null;
  return `${year}-${mm}-${String(day).padStart(2, "0")}`;
}

// คืน null ถ้าข้อความนี้ไม่ใช่ oil price broadcast หรือดึงค่าที่ต้องการไม่ครบ
function parseOilMessage(text) {
  if (!text || !/World Oil Price/i.test(text)) return null;

  const dateMatch = text.match(/\(\$\/B\)\s+(\d{1,2})\s+([A-Za-z]+)\s+(\d{4}):?/);
  const ulg95Match = text.match(/ULG 95 \(S'pore\)\s+([\d.]+)/i);
  const dieselMatch = text.match(/GO 0\.001%S\s+([\d.]+)/i);

  if (!dateMatch || !ulg95Match || !dieselMatch) return null;

  const date = toIsoDate(dateMatch[1], dateMatch[2], dateMatch[3]);
  if (!date) return null;

  return {
    date,
    ULG95_SG: parseFloat(ulg95Match[1]),
    DIESEL_SG: parseFloat(dieselMatch[1]),
  };
}

module.exports = { parseOilMessage };
