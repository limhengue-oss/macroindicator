#!/bin/bash
# รัน fetch_and_push.R บน local
# ต้องตั้ง env var ก่อน:
#   export FRED_API_KEY="your_fred_key"
#   export GCP_SA_KEY="$(cat service-account.json)"

cd "$(dirname "$0")"

if [ -z "$FRED_API_KEY" ]; then echo "ERROR: FRED_API_KEY not set"; exit 1; fi
if [ -z "$GCP_SA_KEY" ]; then echo "ERROR: GCP_SA_KEY not set"; exit 1; fi

Rscript fetch_and_push.R
