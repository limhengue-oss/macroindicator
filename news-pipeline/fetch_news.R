library(httr2)
library(xml2)
library(jsonlite)
library(dplyr)

# ─── Config ───────────────────────────────────────────────────────────────────
GEMINI_API_KEY  <- Sys.getenv("GEMINI_API_KEY")
FIREBASE_URL    <- Sys.getenv("FIREBASE_URL")
FIREBASE_TOKEN  <- Sys.getenv("FIREBASE_TOKEN")
FT_COOKIE       <- Sys.getenv("FT_COOKIE")

MAX_PER_FEED <- 5  # จำกัดข่าวต่อ feed ไม่ให้เกิน token limit

RSS_FEEDS <- list(
  list(name = "Economist Finance",  url = "https://www.economist.com/finance-and-economics/rss.xml"),
  list(name = "Economist Business", url = "https://www.economist.com/business/rss.xml"),
  list(name = "Bangkok Post",       url = "https://www.bangkokpost.com/rss/data/topstories.xml"),
  list(name = "Bangkok Post Biz",   url = "https://www.bangkokpost.com/rss/data/business.xml"),
  list(name = "Prachachat",         url = "https://www.prachachat.net/feed")
)

# Reuters ใช้ feedburner แทน (GitHub Actions IP ถูก block โดยตรง)
RSS_FEEDS <- c(RSS_FEEDS, list(
  list(name = "Reuters World",    url = "https://feeds.feedburner.com/reuters/worldNews"),
  list(name = "Reuters Business", url = "https://feeds.feedburner.com/reuters/businessNews")
))

# FT เพิ่มเฉพาะถ้ามี cookie
if (nchar(FT_COOKIE) > 0) {
  RSS_FEEDS <- c(RSS_FEEDS, list(
    list(name = "FT", url = "https://www.ft.com/rss/home")
  ))
}

# ─── 1. ดึง RSS ───────────────────────────────────────────────────────────────
fetch_rss <- function(feed) {
  tryCatch({
    req <- request(feed$url) |>
      req_headers(
        "User-Agent" = "Mozilla/5.0",
        "Cookie"     = if (grepl("ft.com", feed$url)) FT_COOKIE else ""
      ) |>
      req_timeout(15)

    resp  <- req_perform(req)
    xml   <- read_xml(resp_body_string(resp))
    items <- xml_find_all(xml, ".//item")

    # จำกัด MAX_PER_FEED ต่อ feed
    items <- head(items, MAX_PER_FEED)

    lapply(items, function(item) {
      list(
        source = feed$name,
        title  = xml_text(xml_find_first(item, "title")),
        url    = xml_text(xml_find_first(item, "link")),
        body   = xml_text(xml_find_first(item, "description"))
      )
    })
  }, error = function(e) {
    message("Feed failed: ", feed$name, " — ", e$message)
    list()
  })
}

all_items <- unlist(lapply(RSS_FEEDS, fetch_rss), recursive = FALSE)
message("Fetched ", length(all_items), " articles")

# ─── 2. เรียก Gemini ──────────────────────────────────────────────────────────
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

call_gemini <- function(prompt) {
  body <- list(
    contents = list(list(parts = list(list(text = prompt))))
  )

  resp <- request("https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") |>
    req_url_query(key = GEMINI_API_KEY) |>
    req_headers("Content-Type" = "application/json") |>
    req_body_json(body) |>
    req_timeout(60) |>
    req_perform()

  result <- resp_body_json(resp)
  raw    <- result$candidates[[1]]$content$parts[[1]]$text
  raw    <- gsub("```json|```", "", raw)
  fromJSON(trimws(raw))
}

prompt    <- build_prompt(all_items)
news_list <- call_gemini(prompt)
message("Gemini selected ", nrow(news_list), " articles")

# ─── 3. Push Firestore ────────────────────────────────────────────────────────
today <- format(Sys.Date(), "%Y-%m-%d")

to_firestore_value <- function(x) {
  if (is.character(x)) list(stringValue = x)
  else if (is.numeric(x)) list(doubleValue = x)
  else list(stringValue = as.character(x))
}

news_array <- lapply(seq_len(nrow(news_list)), function(i) {
  row <- news_list[i, ]
  list(mapValue = list(fields = list(
    title      = to_firestore_value(row$title),
    summary_th = to_firestore_value(row$summary_th),
    source     = to_firestore_value(row$source),
    url        = to_firestore_value(row$url),
    why_picked = to_firestore_value(row$why_picked)
  )))
})

all_news_array <- lapply(all_items, function(x) {
  list(mapValue = list(fields = list(
    title  = to_firestore_value(x$title),
    source = to_firestore_value(x$source),
    url    = to_firestore_value(x$url),
    body   = to_firestore_value(x$body)
  )))
})

doc <- list(fields = list(
  date       = list(stringValue = today),
  fetched_at = list(stringValue = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")),
  news       = list(arrayValue = list(values = news_array)),
  all_news   = list(arrayValue = list(values = all_news_array))
))

request(paste0(FIREBASE_URL, "/daily_news/", today)) |>
  req_method("PATCH") |>
  req_headers(
    "Authorization" = paste("Bearer", FIREBASE_TOKEN),
    "Content-Type"  = "application/json"
  ) |>
  req_body_json(doc) |>
  req_timeout(30) |>
  req_perform()

message("Done — pushed daily_news/", today)
