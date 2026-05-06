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

# SNS / ブログ誘導 CTA (任意, 未設定時は空文字 → JS 側で該当リンク非表示)
# 区切りに | を使うため、URL 中に | が含まれていると壊れる点に注意 (現実的に発生しない)
sed -i -E "s|\"\\[SOCIAL_TWITTER\\]\"|\"${SOCIAL_TWITTER:-}\"|" main.js
sed -i -E "s|\"\\[SOCIAL_INSTAGRAM\\]\"|\"${SOCIAL_INSTAGRAM:-}\"|" main.js
sed -i -E "s|\"\\[SOCIAL_BLOG\\]\"|\"${SOCIAL_BLOG:-}\"|" main.js

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
else
  echo "$LOG WARN: ADMIN_FILENAME 未設定。管理画面はビルドしない (live のみ)"
fi

echo "$LOG main.js を生成完了 ($(wc -c < main.js) bytes)"
