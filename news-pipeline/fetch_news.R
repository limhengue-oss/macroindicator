library(httr2)
library(xml2)
library(jsonlite)
library(dplyr)

# ─── Config ───────────────────────────────────────────────────────────────────
GEMINI_API_KEY <- Sys.getenv("GEMINI_API_KEY")
FIREBASE_URL   <- Sys.getenv("FIREBASE_URL")
FIREBASE_TOKEN <- Sys.getenv("FIREBASE_TOKEN")
FT_COOKIE      <- Sys.getenv("FT_COOKIE")

MAX_PER_FEED <- 10

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
  list(name = "Krungthep Turakij",  url = "https://news.google.com/rss/search?q=site:bangkokbiznews.com&hl=th&gl=TH&ceid=TH:th")
)

if (nchar(FT_COOKIE) > 0) {
  RSS_FEEDS <- c(RSS_FEEDS, list(list(name = "FT", url = "https://www.ft.com/rss/home")))
}

# ─── 1. ดึง RSS ───────────────────────────────────────────────────────────────
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
    items <- head(items, MAX_PER_FEED)

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

  paste0(
    "คุณเป็นนักวิเคราะห์เศรษฐศาสตร์และการเงิน\n",
    "จากข่าวด้านล่าง เลือก 5 ข่าวที่สำคัญที่สุดโดยพิจารณาจาก:\n",
    "- ผลกระทบต่อ Fed, ดอกเบี้ย, เงินเฟ้อ หรือ macro global\n",
    "- ผลกระทบต่อเศรษฐกิจไทย / SEA\n",
    "- ผลกระทบต่อ SET หรือ asset prices\n",
    "- มี surprise factor สูง หรือเปลี่ยน market narrative\n",
    "ตัดข่าว routine, ซ้ำ, หรือ opinion ไม่มี hard news\n\n",
    "ตอบเป็น JSON array เท่านั้น ไม่มี markdown ไม่มี backtick:\n",
    "[{\"title\":\"...\",\"summary_th\":\"สรุป 3 ประโยคภาษาไทย\",",
    "\"source\":\"...\",\"url\":\"...\",\"why_picked\":\"เหตุผล 1 ประโยคภาษาไทย\"}]\n\n",
    "ข่าว:\n", articles
  )
}

call_gemini <- function(prompt, max_retries = 3) {
  for (attempt in seq_len(max_retries)) {
    result <- tryCatch({
      resp <- request("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") |>
        req_url_query(key = GEMINI_API_KEY) |>
        req_headers("Content-Type" = "application/json") |>
        req_body_json(list(contents = list(list(parts = list(list(text = prompt)))))) |>
        req_timeout(60) |>
        req_perform()
      list(ok = TRUE, resp = resp)
    }, error = function(e) {
      message("Gemini attempt ", attempt, " failed: ", e$message)
      list(ok = FALSE)
    })
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
message("Gemini selected ", nrow(news_list), " articles")

# ─── 4. Push Firestore ────────────────────────────────────────────────────────
to_fs <- function(x) {
  if (is.character(x)) list(stringValue = x)
  else list(stringValue = as.character(x))
}

news_array <- lapply(seq_len(nrow(news_list)), function(i) {
  r <- news_list[i, ]
  list(mapValue = list(fields = list(
    title      = to_fs(r$title),
    summary_th = to_fs(r$summary_th),
    source     = to_fs(r$source),
    url        = to_fs(r$url),
    why_picked = to_fs(r$why_picked)
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

request(paste0(FIREBASE_URL, "/daily_news/", DOC_ID)) |>
  req_method("PATCH") |>
  req_headers(
    "Authorization" = paste("Bearer", FIREBASE_TOKEN),
    "Content-Type"  = "application/json"
  ) |>
  req_body_json(doc) |>
  req_timeout(30) |>
  req_perform()

message("Done — pushed daily_news/", DOC_ID)
