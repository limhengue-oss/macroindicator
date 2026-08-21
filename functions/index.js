const crypto = require("crypto");
const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore } = require("firebase-admin/firestore");
const { parseOilMessage } = require("./parseOilMessage");

initializeApp();
const db = getFirestore();

const LINE_CHANNEL_SECRET = defineSecret("LINE_CHANNEL_SECRET");
const LINE_CHANNEL_ACCESS_TOKEN = defineSecret("LINE_CHANNEL_ACCESS_TOKEN");
const EXPORT_API_KEY = defineSecret("EXPORT_API_KEY");

async function replyMessage(replyToken, text, accessToken) {
  const resp = await fetch("https://api.line.me/v2/bot/message/reply", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${accessToken}`,
    },
    body: JSON.stringify({
      replyToken,
      messages: [{ type: "text", text }],
    }),
  });
  if (!resp.ok) {
    logger.warn(`LINE reply failed: ${resp.status} ${await resp.text()}`);
  }
}

function isValidSignature(rawBody, signatureHeader, channelSecret) {
  if (!signatureHeader) return false;
  const expected = crypto
    .createHmac("sha256", channelSecret)
    .update(rawBody)
    .digest("base64");
  return crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(signatureHeader));
}

// ── series/{docId} upsert ──────────────────────────────────────────
// เขียนเข้า collection `series` schema เดียวกับที่ fetch_*.R ทุกตัวใช้
// ({name, updated, data:[{d,v}]}) แทนที่จะแยกเป็น collection `oil_prices`
// ของตัวเอง (ของเดิม 1 doc/วัน) — รวมเป็น schema เดียวกันหมดเพื่อไม่ต้องมี
// Firestore rule/query แยกสำหรับ SG_ULG95/SG_HDS/DUBAI อีกต่อไป (เดิมต้อง
// เพิ่ม `allow read` แยกให้ `oil_prices` และ query แยกในหน้าเว็บ)
//
// read-modify-write ต่อ field ต่อข้อความ (แทนที่ point เดิมถ้าวันซ้ำ, กัน
// ส่งข้อความเดิมซ้ำ/แก้ไขราคาย้อนหลังได้ปลอดภัย) — volume ต่ำ (~1
// ข้อความ/วัน) ไม่มีปัญหาเรื่อง contention
const SERIES_DOC_IDS = {
  ULG95_SG: { docId: "ULG95_SG", name: "PEIT — ULG 95 (S'pore)" },
  DIESEL_SG: { docId: "DIESEL_SG", name: "PEIT — GO 0.001%S (S'pore Diesel)" },
  DUBAI: { docId: "DUBAI", name: "PEIT — Dubai crude" },
};

async function upsertSeriesPoint(docId, name, date, value) {
  const ref = db.collection("series").doc(docId);
  const snap = await ref.get();
  const existing = snap.exists ? snap.data().data || [] : [];
  const filtered = existing.filter((p) => p.d !== date);
  filtered.push({ d: date, v: value });
  filtered.sort((a, b) => (a.d < b.d ? -1 : a.d > b.d ? 1 : 0));
  await ref.set(
    { name, updated: new Date().toISOString(), data: filtered },
    { merge: true }
  );
}

exports.lineOilWebhook = onRequest(
  { secrets: [LINE_CHANNEL_SECRET, LINE_CHANNEL_ACCESS_TOKEN], region: "asia-southeast1" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("Method Not Allowed");
      return;
    }

    const signature = req.get("x-line-signature");
    if (!isValidSignature(req.rawBody, signature, LINE_CHANNEL_SECRET.value())) {
      logger.warn("Invalid LINE signature");
      res.status(401).send("Invalid signature");
      return;
    }

    const events = req.body?.events || [];

    for (const event of events) {
      if (event.type !== "message" || event.message?.type !== "text") continue;

      const parsed = parseOilMessage(event.message.text);
      if (!parsed) {
        logger.info("Skipped non-oil-price message");
        continue;
      }

      await upsertSeriesPoint(
        SERIES_DOC_IDS.ULG95_SG.docId,
        SERIES_DOC_IDS.ULG95_SG.name,
        parsed.date,
        parsed.ULG95_SG
      );
      await upsertSeriesPoint(
        SERIES_DOC_IDS.DIESEL_SG.docId,
        SERIES_DOC_IDS.DIESEL_SG.name,
        parsed.date,
        parsed.DIESEL_SG
      );
      if (parsed.DUBAI !== undefined) {
        await upsertSeriesPoint(
          SERIES_DOC_IDS.DUBAI.docId,
          SERIES_DOC_IDS.DUBAI.name,
          parsed.date,
          parsed.DUBAI
        );
      }
      // rawText ไม่ fit กับ schema series (array ของ {d,v} ล้วนๆ ไม่มีที่เก็บ
      // text) — log ไว้ใน Cloud Logging แทน ดูย้อนหลังได้ด้วย
      // `firebase functions:log` (retention ตาม Cloud Logging default)
      logger.info(`Saved series/${parsed.date}`, { rawText: parsed.rawText });

      if (event.replyToken) {
        const dubaiPart = parsed.DUBAI !== undefined ? `, DUBAI=${parsed.DUBAI}` : "";
        await replyMessage(
          event.replyToken,
          `บันทึกแล้ว ${parsed.date}: ULG95_SG=${parsed.ULG95_SG}, DIESEL_SG=${parsed.DIESEL_SG}${dubaiPart}`,
          LINE_CHANNEL_ACCESS_TOKEN.value()
        );
      }
    }

    // ต้องตอบ 200 เสมอ ไม่งั้น LINE จะ retry webhook ซ้ำ
    res.status(200).send("OK");
  }
);

// ── exportSeriesData ─────────────────────────────────────────────
// ช่องทางเดียวที่ Excel/VBA (หรือ tool ภายนอกอื่นๆ) ใช้ดึงข้อมูล series ได้
// — gate ด้วย X-API-Key แทนการยิง Firestore REST ตรง (ซึ่งจะโดน App Check
// บล็อกเมื่อเปิด enforcement) เขียนผ่าน Admin SDK ฝั่ง server บทบาทนี้จึง
// bypass App Check ได้เองโดยธรรมชาติ ไม่ต้องทำอะไรเพิ่มฝั่งนี้
//
// GET /exportSeriesData?docId=EPPO_DIESEL_RETAIL
// header: X-API-Key: <secret จาก Secret Manager, แจกให้ทีมผ่าน SharePoint>
// response: text/csv "date,value\n2013-03-07,29.99\n..." (เรียงตามวันที่)
//   — เลือกส่ง CSV แทน JSON ดิบของ Firestore เพราะ parse ใน VBA ง่ายกว่ามาก
//   (แค่ split บรรทัด/comma ไม่ต้องพึ่ง regex เดาโครงสร้าง JSON เหมือนตอนยิง
//   Firestore REST ตรง)
exports.exportSeriesData = onRequest(
  { secrets: [EXPORT_API_KEY], region: "asia-southeast1" },
  async (req, res) => {
    if (req.method !== "GET") {
      res.status(405).send("Method Not Allowed");
      return;
    }

    const key = req.get("x-api-key");
    if (!key || key !== EXPORT_API_KEY.value()) {
      logger.warn("exportSeriesData: invalid or missing X-API-Key");
      res.status(401).send("Unauthorized");
      return;
    }

    const docId = req.query.docId;
    if (!docId || typeof docId !== "string") {
      res.status(400).send("Missing docId query param");
      return;
    }

    const snap = await db.collection("series").doc(docId).get();
    if (!snap.exists) {
      res.status(404).send(`series/${docId} not found`);
      return;
    }

    const data = snap.data().data || [];
    const sorted = [...data].sort((a, b) => (a.d < b.d ? -1 : a.d > b.d ? 1 : 0));
    const csv = ["date,value", ...sorted.map((p) => `${p.d},${p.v}`)].join("\n");

    logger.info(`exportSeriesData: served series/${docId} (${sorted.length} points)`);
    res.set("Content-Type", "text/csv; charset=utf-8");
    res.status(200).send(csv);
  }
);
