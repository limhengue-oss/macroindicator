library(httr2)
library(xml2)
library(jsonlite)
library(dplyr)

# ─── Config ───────────────────────────────────────────────────────────────────
GEMINI_API_KEY <- Sys.getenv("GEMINI_API_KEY")
FIREBASE_URL   <- Sys.getenv("FIREBASE_URL")
FIREBASE_TOKEN <- Sys.getenv("FIREBASE_TOKEN")
FT_COOKIE      <- Sys.getenv("FT_COOKIE")

MAX_PER_FEED_FALLBACK <- 10  # ใช้เมื่อ feed ไม่มี pubDate ให้เทียบ (เช่น Nikkei Asia)
MAX_PER_FEED_SAFETY   <- 50  # เพดานกันกรณี feed เดียวมีข่าวสดเยอะผิดปกติในวันเดียว
FRESHNESS_HOURS       <- 24  # เอาเฉพาะข่าวที่ตีพิมพ์ภายในกี่ชั่วโมงที่ผ่านมา

# ระบุ session: morning (00:00 UTC) หรือ afternoon (06:00 UTC)
utc_hour <- as.integer(format(Sys.time(), "%H", tz = "UTC"))
SESSION   <- if (utc_hour < 6) "morning" else "afternoon"
TODAY     <- format(Sys.Date(), "%Y-%m-%d")
DOC_ID    <- paste0(TODAY, "-", SESSION)

message("Session: ", SESSION, " | Doc: ", DOC_ID)

# ─── RSS Feeds ────────────────────────────────────────────────────────────────
RSS_FEEDS <- list(
  list(name = "Economist Finance",  url = "https://www.economist.com/finance-and-economics/rss.xml"),
  list(name = "Economist Business", url = "https://www.economist.com/business/rss.xml"),
  list(name = "Bangkok Post",       url = "https://www.bangkokpost.com/rss/data/topstories.xml"),
  list(name = "Bangkok Post Biz",   url = "https://www.bangkokpost.com/rss/data/business.xml"),
  list(name = "Prachachat",         url = "https://www.prachachat.net/feed"),
  list(name = "Reuters World",      url = "https://feeds.feedburner.com/reuters/worldNews"),
  list(name = "Reuters Business",   url = "https://feeds.feedburner.com/reuters/businessNews"),
  list(name = "MarketWatch",        url = "https://www.marketwatch.com/rss/topstories"),
  list(name = "CNBC Economy",       url = "https://www.cnbc.com/id/20910258/device/rss/rss.html"),
  list(name = "Investing.com Economy",     url = "https://www.investing.com/rss/news_14.rss"),
  list(name = "Investing.com Econ Indicators", url = "https://www.investing.com/rss/news_95.rss"),
  list(name = "Nikkei Asia",        url = "https://asia.nikkei.com/rss/feed/nar"),
  # bangkokbiznews.com ไม่มี RSS ให้ใช้แล้ว (เว็บเปลี่ยนเป็น SPA) — ใช้ Google News site-search แทน
  # when:1d กันข่าวเก่าหลุดเข้ามา (เจอเคสข่าวปี 2014 ตอนไม่ใส่ตัวกรอง)
  list(name = "Krungthep Turakij",  url = "https://news.google.com/rss/search?q=site:bangkokbiznews.com+when:1d&hl=th&gl=TH&ceid=TH:th")
)

if (nchar(FT_COOKIE) > 0) {
  RSS_FEEDS <- c(RSS_FEEDS, list(list(name = "FT", url = "https://www.ft.com/rss/home")))
}

# ─── 1. ดึง RSS ───────────────────────────────────────────────────────────────

# แปลง pubDate/date ของ RSS (รูปแบบไม่ตรงกันในแต่ละ feed) เป็นเวลา UTC
# ตัด timezone token ท้ายสตริงทิ้งแล้วตีความเป็น UTC (ยอมรับความคลาดเคลื่อนเล็กน้อย
# จาก offset ที่ไม่ใช่ 0 เพราะใช้แค่กรอง "ข่าวใหม่ภายใน 24 ชม." ไม่ต้องแม่นระดับนาที)
parse_pubdate <- function(x) {
  if (is.na(x) || !nzchar(x)) return(as.POSIXct(NA, tz = "UTC"))
  x <- sub("\\s*(GMT|UTC|[+-]\\d{4})\\s*$", "", trimws(x))
  for (fmt in c("%a, %d %b %Y %H:%M:%S", "%a, %d %b %Y %H:%M", "%Y-%m-%dT%H:%M:%S")) {
    t <- as.POSIXct(x, format = fmt, tz = "UTC")
    if (!is.na(t)) return(t)
  }
  as.POSIXct(NA, tz = "UTC")
}

fetch_rss <- function(feed) {
  tryCatch({
    resp  <- request(feed$url) |>
      req_headers(
        "User-Agent" = "Mozilla/5.0",
        "Cookie"     = if (grepl("ft.com", feed$url)) FT_COOKIE else ""
      ) |>
      req_timeout(15) |>
      req_perform()

    doc <- read_xml(resp_body_string(resp))
    xml_ns_strip(doc)
    items <- xml_find_all(doc, ".//item")

    dates <- vapply(items, function(item) {
      raw <- xml_text(xml_find_first(item, "pubDate|date"))
      as.numeric(parse_pubdate(raw))
    }, numeric(1))

    cutoff <- as.numeric(Sys.time() - FRESHNESS_HOURS * 3600)
    has_date <- !is.na(dates)

    if (any(has_date)) {
      # feed มี pubDate ให้เทียบ → กรองเฉพาะข่าวสดภายใน FRESHNESS_HOURS
      items <- items[has_date & dates >= cutoff]
    } else {
      # feed ไม่มี pubDate เลย (เช่น Nikkei Asia) → fallback เอาข่าวใหม่สุดตามลำดับ feed
      items <- head(items, MAX_PER_FEED_FALLBACK)
    }
    items <- head(items, MAX_PER_FEED_SAFETY)

    lapply(items, function(item) list(
      source = feed$name,
      title  = xml_text(xml_find_first(item, "title")),
      url    = xml_text(xml_find_first(item, "link")),
      body   = xml_text(xml_find_first(item, "description"))
    ))
  }, error = function(e) {
    message("Feed failed: ", feed$name, " — ", e$message)
    list()
  })
}

all_items <- unlist(lapply(RSS_FEEDS, fetch_rss), recursive = FALSE)
message("Fetched ", length(all_items), " articles")

# ─── 2. ดึง URL ที่เคยเก็บแล้ว (dedup) ──────────────────────────────────────
fetch_existing_urls <- function() {
  urls <- c()

  # afternoon → เช็คกับ morning วันเดียวกัน
  # morning   → เช็คกับ afternoon เมื่อวาน
  yesterday  <- format(Sys.Date() - 1, "%Y-%m-%d")
  check_docs <- if (SESSION == "afternoon") {
    c(paste0(TODAY, "-morning"))
  } else {
    c(paste0(yesterday, "-morning"), paste0(yesterday, "-afternoon"))
  }

  for (doc_id in check_docs) {
    tryCatch({
      resp <- request(paste0(FIREBASE_URL, "/daily_news/", doc_id)) |>
        req_headers("Authorization" = paste("Bearer", FIREBASE_TOKEN)) |>
        req_timeout(15) |>
        req_perform()

      doc <- resp_body_json(resp)
      items <- doc$fields$all_news$arrayValue$values
      if (!is.null(items)) {
        doc_urls <- sapply(items, function(x) x$mapValue$fields$url$stringValue)
        urls <- c(urls, doc_urls)
      }
    }, error = function(e) {
      message("No existing doc: ", doc_id)
    })
  }
  unique(urls)
}

existing_urls <- fetch_existing_urls()
message("Existing URLs to dedup: ", length(existing_urls))

# กรองข่าวซ้ำออก
all_items <- Filter(function(x) !x$url %in% existing_urls, all_items)
message("After dedup: ", length(all_items), " articles")

if (length(all_items) == 0) {
  message("No new articles — skipping")
  quit(status = 0)
}

# ─── 3. เรียก Gemini ──────────────────────────────────────────────────────────

# theme คงที่ + "อื่นๆ" เป็น bucket สำหรับข่าวสำคัญที่ไม่เข้าพวกไหนเลย
THEMES <- c(
  "สงครามการค้า",
  "สงครามอิหร่าน",
  "Fed/ดอกเบี้ย/เงินเฟ้อ",
  "เศรษฐกิจไทย/SEA",
  "ตลาดทุน/SET",
  "อื่นๆ"
)

build_prompt <- function(items) {
  articles <- paste(
    seq_along(items),
    sapply(items, function(x) paste0(
      "[", x$source, "] ", x$title, "\n",
      substr(x$body, 1, 80), "\n",
      "URL: ", x$url
    )),
    sep = ". ",
    collapse = "\n\n"
  )

  theme_list <- paste0("\"", THEMES, "\"", collapse = ", ")

  paste0(
    "คุณเป็นนักวิเคราะห์เศรษฐศาสตร์และการเงิน\n",
    "จากข่าวด้านล่าง เลือกข่าวที่สำคัญที่สุด (สูงสุด 15 ข่าว) โดยพิจารณาจาก:\n",
    "- ผลกระทบต่อ Fed, ดอกเบี้ย, เงินเฟ้อ หรือ macro global\n",
    "- ผลกระทบต่อเศรษฐกิจไทย / SEA\n",
    "- ผลกระทบต่อ SET หรือ asset prices\n",
    "- ความเกี่ยวข้องกับสงครามการค้า หรือสงครามอิหร่าน/ตะวันออกกลาง\n",
    "- มี surprise factor สูง หรือเปลี่ยน market narrative\n",
    "ตัดข่าว routine, ซ้ำ, หรือ opinion ไม่มี hard news\n\n",
    "**ถ้าข่าวที่เลือกหลายข่าวพูดถึงเรื่องเดียวกัน (สำนักข่าวหลายเจ้ารายงานเรื่อง\n",
    "เดียวกัน หรือข่าวต่อเนื่องในประเด็นเดียวกัน) ให้รวมเป็นกลุ่มเดียว เขียนสรุป\n",
    "แบบ punchline สั้นๆ ครอบคลุมทุกแหล่งในกลุ่มนั้น แทนที่จะแยกสรุปทีละข่าว**\n",
    "ข่าวที่ไม่เกี่ยวกับข่าวอื่นเลยก็ยังเป็นกลุ่มเดี่ยวได้ (sources มีแค่ 1 รายการ)\n\n",
    "จากนั้นจัดแต่ละกลุ่มเข้า theme หนึ่งใน [", theme_list, "] ",
    "โดยเลือก theme ที่ตรงที่สุดเพียงอันเดียว ถ้าไม่เข้าพวกไหนเลยให้ใช้ \"อื่นๆ\"\n\n",
    "ตอบเป็น JSON array เท่านั้น ไม่มี markdown ไม่มี backtick ",
    "โดยแต่ละ element คือ 1 กลุ่มข่าว (1 ข่าวเดี่ยวหรือหลายข่าวที่รวมกัน):\n",
    "[{\"theme\":\"...\",",
    "\"headline\":\"พาดหัวรวมสั้นๆ ภาษาไทย ไม่เกิน 15 คำ\",",
    "\"summary_th\":\"สรุปรวม 2-3 ประโยคภาษาไทย ครอบคลุมทุกข่าวในกลุ่ม แบบ punchline\",",
    "\"why_picked\":\"เหตุผลที่สำคัญ 1 ประโยคภาษาไทย\",",
    "\"sources\":[{\"title\":\"...\",\"source\":\"...\",\"url\":\"...\"}]}]\n\n",
    "ข่าว:\n", articles
  )
}

call_gemini <- function(prompt, max_retries = 3) {
  message("Prompt size: ", nchar(prompt), " chars")
  if (nchar(GEMINI_API_KEY) == 0) stop("GEMINI_API_KEY is empty — check GitHub secret")

  for (attempt in seq_len(max_retries)) {
    result <- tryCatch({
      resp <- request("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") |>
        req_url_query(key = GEMINI_API_KEY) |>
        req_headers("Content-Type" = "application/json") |>
        req_body_json(list(
          contents = list(list(parts = list(list(text = prompt)))),
          # gemini-2.5-flash เปิด "thinking" เป็น default — งาน clustering/summarize
          # นี้ไม่ต้องการ deep reasoning ขนาดนั้น แต่กลับกินเวลาคิดจนเกิน timeout แม้ 150s
          # (เห็น 0 bytes received แปลว่าโมเดลยังไม่เริ่มตอบเลย ไม่ใช่ network fail) ปิดไปเลย
          generationConfig = list(thinkingConfig = list(thinkingBudget = 0))
        )) |>
        req_timeout(180) |>  # buffer เผื่อไว้ แม้ปิด thinking แล้วก็ตาม
        req_error(is_error = function(resp) FALSE) |>  # ไม่ throw เอง — เช็ค status ข้างล่างเพื่อ print body ได้
        req_perform()
      list(ok = TRUE, resp = resp)
    }, error = function(e) {
      # error ระดับนี้คือ curl/network fail (DNS, timeout, connection reset) ไม่ใช่ HTTP status
      message("Gemini attempt ", attempt, " network error: ", conditionMessage(e))
      if (!is.null(e$parent)) message("  parent: ", conditionMessage(e$parent))
      list(ok = FALSE)
    })

    if (result$ok) {
      status <- resp_status(result$resp)
      if (status >= 400) {
        body_txt <- tryCatch(resp_body_string(result$resp), error = function(e) "(no body)")
        message("Gemini attempt ", attempt, " HTTP ", status, ": ", substr(body_txt, 1, 500))
        result$ok <- FALSE
      }
    }

    if (result$ok) { resp <- result$resp; break }
    if (attempt < max_retries) Sys.sleep(15)
  }
  if (!result$ok) stop("Gemini failed after ", max_retries, " attempts")

  raw <- resp_body_json(resp)$candidates[[1]]$content$parts[[1]]$text
  raw <- gsub("```json|```", "", raw)
  fromJSON(trimws(raw))
}

prompt    <- build_prompt(all_items)
news_list <- call_gemini(prompt)
message("Gemini selected ", nrow(news_list), " กลุ่มข่าว")

# ─── 4. Push Firestore ────────────────────────────────────────────────────────
to_fs <- function(x) {
  # NA/NULL ต้องแปลงเป็น "" ไม่ใช่ null — Firestore REST API reject
  # {"stringValue": null} เพราะ field ต้องเป็น string เท่านั้น (สาเหตุ HTTP 400
  # ที่เจอตอน push หลังเพิ่ม field "theme" — Gemini อาจไม่ตอบบาง field มาครบ)
  if (is.null(x) || length(x) == 0 || (length(x) == 1 && is.na(x))) return(list(stringValue = ""))
  if (is.character(x)) list(stringValue = x)
  else list(stringValue = as.character(x))
}

# กัน Gemini ตอบ theme ที่ไม่อยู่ใน THEMES (พิมพ์ผิด/ตั้งชื่อเอง) → fallback "อื่นๆ"
normalize_theme <- function(t) if (is.null(t) || is.na(t) || !(t %in% THEMES)) "อื่นๆ" else t

# แต่ละ element ของ news_list ตอนนี้คือ "กลุ่มข่าว" (1 ข่าวเดี่ยว หรือหลายข่าว
# ที่ Gemini รวม punchline เดียวกัน) — r$sources[[1]] คือ data.frame ของ
# แหล่งข่าวย่อยในกลุ่มนั้น (jsonlite ยุบ nested array เป็น list-column ให้)
news_array <- lapply(seq_len(nrow(news_list)), function(i) {
  r <- news_list[i, ]
  cluster_sources <- r$sources[[1]]

  sources_array <- if (!is.null(cluster_sources) && nrow(cluster_sources) > 0) {
    lapply(seq_len(nrow(cluster_sources)), function(j) {
      s <- cluster_sources[j, ]
      list(mapValue = list(fields = list(
        title  = to_fs(s$title),
        source = to_fs(s$source),
        url    = to_fs(s$url)
      )))
    })
  } else list()

  list(mapValue = list(fields = list(
    theme      = to_fs(normalize_theme(r$theme)),
    headline   = to_fs(r$headline),
    summary_th = to_fs(r$summary_th),
    why_picked = to_fs(r$why_picked),
    sources    = list(arrayValue = list(values = sources_array))
  )))
})

all_news_array <- lapply(all_items, function(x) {
  list(mapValue = list(fields = list(
    title  = to_fs(x$title),
    source = to_fs(x$source),
    url    = to_fs(x$url),
    body   = to_fs(x$body)
  )))
})

doc <- list(fields = list(
  date       = list(stringValue = TODAY),
  session    = list(stringValue = SESSION),
  fetched_at = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
  news       = list(arrayValue = list(values = news_array)),
  all_news   = list(arrayValue = list(values = all_news_array))
))

push_result <- tryCatch({
  request(paste0(FIREBASE_URL, "/daily_news/", DOC_ID)) |>
    req_method("PATCH") |>
    req_headers(
      "Authorization" = paste("Bearer", FIREBASE_TOKEN),
      "Content-Type"  = "application/json"
    ) |>
    req_body_json(doc) |>
    req_timeout(30) |>
    req_error(is_error = function(resp) FALSE) |>
    req_perform()
}, error = function(e) {
  message("Firestore push network error: ", conditionMessage(e))
  NULL
})

if (is.null(push_result)) {
  stop("Firestore push failed — network error (ดู log ด้านบน)")
}
status <- resp_status(push_result)
if (status >= 400) {
  message("Firestore push HTTP ", status, ": ", resp_body_string(push_result))
  stop("Firestore push failed with HTTP ", status)
}

message("Done — pushed daily_news/", DOC_ID)
