library(pdftools)
library(stringr)

# ── Config ────────────────────────────────────────────────────────────────────
SAVE_DIR <- "offo_files"

# ── Thai month → number ───────────────────────────────────────────────────────
THAI_MONTHS <- c(
  "ม.ค." = "01", "ก.พ." = "02", "มี.ค." = "03", "เม.ย." = "04",
  "พ.ค." = "05", "มิ.ย." = "06", "ก.ค." = "07", "ส.ค." = "08",
  "ก.ย." = "09", "ต.ค." = "10", "พ.ย." = "11", "ธ.ค." = "12"
)

parse_thai_date <- function(raw) {
  raw <- str_squish(raw)
  m   <- str_match(raw, "(\\d+)\\s+([ก-๙\\.]+)\\s+(\\d{2,4})")
  if (is.na(m[1])) stop(paste("Cannot parse date:", raw))
  day      <- sprintf("%02d", as.integer(m[2]))
  month    <- THAI_MONTHS[m[3]]
  if (is.na(month)) stop(paste("Unknown month:", m[3]))
  year_raw <- as.integer(m[4])
  year_be  <- if (year_raw < 100) year_raw + 2500 else year_raw
  as.Date(paste(year_be - 543, month, day, sep = "-"))
}

# ── Parse single PDF ──────────────────────────────────────────────────────────
parse_offo_pdf <- function(path) {
  text <- pdf_text(path) |> paste(collapse = "\n")
  
  date_raw <- str_match(
    text,
    "สิ้?\\s*นสุด\\s*ณ\\s*วันที่\\s*([\\d]+\\s*[ก-๙\\.]+\\.?\\s*\\d{2,4})"
  )[2]
  if (is.na(date_raw)) stop(paste("Date not found in:", basename(path)))
  
  m <- str_match(text, "ฐานะกองทุน\\s*สุทธิ\\s+(-?[\\d,]+)\\s+(-?[\\d,]+)\\s+(-?[\\d,]+)")
  if (is.na(m[1])) stop(paste("Net fund pattern not found in:", basename(path)))
  
  data.frame(
    filename  = basename(path),
    year      = basename(dirname(path)),
    date      = parse_thai_date(date_raw),
    net_oil   = as.numeric(str_remove_all(m[2], ",")),
    net_lpg   = as.numeric(str_remove_all(m[3], ",")),
    net_total = as.numeric(str_remove_all(m[4], ",")),
    stringsAsFactors = FALSE
  )
}

# ── Parse all PDFs ────────────────────────────────────────────────────────────
parse_all_pdfs <- function(save_dir) {
  paths <- list.files(save_dir, pattern = "\\.pdf$", recursive = TRUE, full.names = TRUE)
  if (length(paths) == 0) stop("No PDF files found in: ", save_dir)
  
  results <- lapply(paths, function(path) {
    cat("Parsing:", basename(path), "\n")
    tryCatch(
      parse_offo_pdf(path),
      error = function(e) { cat("  ERROR:", e$message, "\n"); NULL }
    )
  })
  
  do.call(rbind, Filter(Negate(is.null), results))
}

# ── Main ──────────────────────────────────────────────────────────────────────
df <- parse_all_pdfs(SAVE_DIR)
df <- df[order(df$date), ]
write.csv(df, file.path(SAVE_DIR, "offo_parsed.csv"), row.names = FALSE)
cat("\nบันทึก CSV เสร็จ:", nrow(df), "แถว\n")