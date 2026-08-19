const crypto = require("crypto");
const { onRequest } = require("firebase-functions/v2/https");
const { defineSecret } = require("firebase-functions/params");
const logger = require("firebase-functions/logger");
const { initializeApp } = require("firebase-admin/app");
const { getFirestore, FieldValue } = require("firebase-admin/firestore");
const { parseOilMessage } = require("./parseOilMessage");

initializeApp();
const db = getFirestore();

const LINE_CHANNEL_SECRET = defineSecret("LINE_CHANNEL_SECRET");
const LINE_CHANNEL_ACCESS_TOKEN = defineSecret("LINE_CHANNEL_ACCESS_TOKEN");

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

      const docRef = db.collection("oil_prices").doc(parsed.date);
      await docRef.set(
        {
          ...parsed,
          receivedAt: FieldValue.serverTimestamp(),
        },
        { merge: true }
      );
      logger.info(`Saved oil_prices/${parsed.date}`);

      if (event.replyToken) {
        await replyMessage(
          event.replyToken,
          `บันทึกแล้ว ${parsed.date}: ULG95_SG=${parsed.ULG95_SG}, DIESEL_SG=${parsed.DIESEL_SG}`,
          LINE_CHANNEL_ACCESS_TOKEN.value()
        );
      }
    }

    // ต้องตอบ 200 เสมอ ไม่งั้น LINE จะ retry webhook ซ้ำ
    res.status(200).send("OK");
  }
);
