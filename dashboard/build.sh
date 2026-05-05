#!/bin/bash
# yakiimo-temp-monitor / Cloudflare Pages 用 build script
#
# CF Pages の Build command として呼ばれる:
#   cd dashboard && bash build.sh
# Output directory は dashboard/。
#
# CF Pages Settings → Environment variables (Production scope) に
# 以下を必ず設定すること:
#   - SUPABASE_URL         (例: https://xxxxx.supabase.co)
#   - SUPABASE_ANON_KEY    (Supabase anon public key)
#   - BRAND_NAME           (Web UI に表示する屋号)
#
# 値の検証は厳格 — 未設定なら build を失敗させて誤公開を防ぐ。

set -euo pipefail

LOG="[build]"

# 必須 env 確認
: "${SUPABASE_URL:?$LOG SUPABASE_URL が未設定。CF Pages Settings の Environment variables で設定すること}"
: "${SUPABASE_ANON_KEY:?$LOG SUPABASE_ANON_KEY が未設定}"
: "${BRAND_NAME:?$LOG BRAND_NAME が未設定}"

if [ ! -f main.js.example ]; then
  echo "$LOG ERROR: main.js.example が見つからない (cwd=$(pwd))" >&2
  exit 1
fi

# main.js.example から main.js を生成
cp main.js.example main.js

# const SUPABASE_URL / SUPABASE_ANON_KEY / BRAND_NAME を置換
# CF Pages のビルド環境は GNU sed ゆえ -i は引数なし
# 区切り文字に | を使い、URL 中の / との衝突を回避
sed -i -E "s|^const BRAND_NAME = \".*\";|const BRAND_NAME = \"${BRAND_NAME}\";|" main.js
sed -i -E "s|^const SUPABASE_URL = \".*\";|const SUPABASE_URL = \"${SUPABASE_URL}\";|" main.js
sed -i -E "s|^const SUPABASE_ANON_KEY = \".*\";|const SUPABASE_ANON_KEY = \"${SUPABASE_ANON_KEY}\";|" main.js

# 置換結果のサニティチェック (プレースホルダ残留を検知)
if grep -q "YOUR_PROJECT" main.js || grep -q "YOUR_ANON_KEY" main.js || grep -q '\[屋号\]' main.js; then
  echo "$LOG ERROR: 置換後の main.js にプレースホルダが残留している。env 値を確認すること" >&2
  exit 1
fi

echo "$LOG main.js を生成完了 ($(wc -c < main.js) bytes)"
