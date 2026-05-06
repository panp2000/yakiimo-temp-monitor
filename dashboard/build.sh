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
if grep -qE '^const SUPABASE_URL = "https://YOUR_PROJECT' main.js \
   || grep -qE '^const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY"' main.js \
   || grep -qE '^const BRAND_NAME = "\[屋号\]"' main.js; then
  echo "$LOG ERROR: const 宣言の置換に失敗。env 値と main.js.example のプレースホルダ書式を確認" >&2
  exit 1
fi

# admin template 生成 (ADMIN_FILENAME env が設定されている場合のみ)
if [ -n "${ADMIN_FILENAME:-}" ]; then
  if [ ! -f admin.template.html ]; then
    echo "$LOG ERROR: admin.template.html が見つからない" >&2
    exit 1
  fi
  # ファイル名は ADMIN_FILENAME (拡張子なしで env に入れる前提) + .html
  cp admin.template.html "${ADMIN_FILENAME}.html"
  echo "$LOG admin page を ${ADMIN_FILENAME}.html として出力"
  # cp 成功確認 (file 実在 + size + 全 ls 出力)
  ls -la "${ADMIN_FILENAME}.html"
  echo "$LOG cwd: $(pwd)"
  echo "$LOG dashboard dir 全 file 一覧:"
  ls -la
  echo "$LOG admin file 先頭行: $(head -1 "${ADMIN_FILENAME}.html")"
else
  echo "$LOG WARN: ADMIN_FILENAME 未設定。管理画面はビルドしない (live のみ)"
fi

echo "$LOG main.js を生成完了 ($(wc -c < main.js) bytes)"
