# One-off diagnostic — run via GitHub Actions to see what the goldtraders.or.th
# API actually returns from the runner's IP (can't observe this from local,
# where the request already succeeds normally).
suppressPackageStartupMessages({ library(httr2) })
`%||%` <- function(x, y) if (is.null(x) || length(x) == 0 || is.na(x)) y else x

variants <- list(
  list(label = "current UA (macroindicator-bot)",
       headers = c(`User-Agent` = "Mozilla/5.0 (compatible; macroindicator-bot/1.0)", Accept = "application/json")),
  list(label = "real Chrome UA, no bot string",
       headers = c(`User-Agent` = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36",
                   Accept = "application/json, text/plain, */*",
                   `Accept-Language` = "en-US,en;q=0.9,th;q=0.8",
                   Referer = "https://newgta.goldtraders.or.th/")),
  list(label = "no custom headers at all",
       headers = c())
)

for (v in variants) {
  cat("\n=====", v$label, "=====\n")
  req <- request("https://newgta.goldtraders.or.th/api/GoldPricesDaily/pricechanges") |>
    req_url_query(StartDate = "2026-08-01", EndDate = "2026-08-15") |>
    req_timeout(30) |> req_error(is_error = \(r) FALSE)
  if (length(v$headers) > 0) req <- req |> req_headers(!!!as.list(v$headers))
  resp <- tryCatch(req_perform(req), error = function(e) { cat("REQUEST ERROR:", conditionMessage(e), "\n"); NULL })
  if (is.null(resp)) next
  cat("status:", resp_status(resp), "\n")
  cat("content-type:", resp_header(resp, "content-type") %||% "(none)", "\n")
  cat("cf-ray:", resp_header(resp, "cf-ray") %||% "(none)", "\n")
  cat("server:", resp_header(resp, "server") %||% "(none)", "\n")
  body <- tryCatch(resp_body_string(resp), error = function(e) paste("BODY READ ERROR:", conditionMessage(e)))
  cat("body length:", nchar(body), "chars\n")
  cat("body preview:", substr(body, 1, 300), "\n")
}

cat("\n=== runner egress IP ===\n")
ip_resp <- tryCatch(request("https://api.ipify.org") |> req_perform(), error = function(e) NULL)
if (!is.null(ip_resp)) cat("egress IP:", resp_body_string(ip_resp), "\n")
