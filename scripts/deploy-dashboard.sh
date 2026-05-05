#!/bin/bash
# yakiimo-temp-monitor / dashboard 一発デプロイスクリプト
#
# firmware-esphome/secrets.yaml の値を dashboard/main.js に同期した上で
# Cloudflare Pages へ wrangler 経由でデプロイする。
#
# 同期対象:
#   - brand_name        → const BRAND_NAME
#   - supabase_url      → const SUPABASE_URL
#   - supabase_anon_key → const SUPABASE_ANON_KEY
#
# Usage:
#   bash scripts/deploy-dashboard.sh
#
# 想定環境: macOS (BSD sed)
set -euo pipefail

LOG_PREFIX="[deploy-dashboard]"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_YAML="${PROJECT_ROOT}/firmware-esphome/secrets.yaml"
DASHBOARD_DIR="${PROJECT_ROOT}/dashboard"
MAIN_JS="${DASHBOARD_DIR}/main.js"
MAIN_JS_EXAMPLE="${DASHBOARD_DIR}/main.js.example"

# --- 前提チェック ---
if [ ! -f "${SECRETS_YAML}" ]; then
  echo "${LOG_PREFIX} ERROR: secrets.yaml が見つからない: ${SECRETS_YAML}" >&2
  exit 1
fi

if [ ! -f "${MAIN_JS}" ]; then
  echo "${LOG_PREFIX} ERROR: dashboard/main.js が見つからない。" >&2
  echo "${LOG_PREFIX}        cp ${MAIN_JS_EXAMPLE} ${MAIN_JS} を実行してから再度試して下さい。" >&2
  exit 1
fi

# --- YAML 値抽出ヘルパー ---
# `key: "value"` または `key: value` から値を抽出してクォートを剥がす
extract_yaml() {
  local key="$1"
  local file="$2"
  grep -E "^[[:space:]]*${key}:" "${file}" | head -1 \
    | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/"
}

# --- 値の抽出 ---
BRAND_NAME_VALUE="$(extract_yaml 'brand_name' "${SECRETS_YAML}" || true)"
SUPABASE_URL_VALUE="$(extract_yaml 'supabase_url' "${SECRETS_YAML}" || true)"
SUPABASE_ANON_KEY_VALUE="$(extract_yaml 'supabase_anon_key' "${SECRETS_YAML}" || true)"

# --- main.js を sed で書き換え ---
# BSD sed (macOS) は -i に空文字列を必須とする。'' を渡してバックアップなし。

# brand_name: 空ならプレースホルダ
if [ -z "${BRAND_NAME_VALUE}" ]; then
  BRAND_NAME_VALUE="[屋号]"
  echo "${LOG_PREFIX} WARN: secrets.yaml に brand_name の値が無い。プレースホルダ \"[屋号]\" を書き込む。"
else
  echo "${LOG_PREFIX} secrets.yaml から brand_name を同期: \"${BRAND_NAME_VALUE}\""
fi
# sed の区切りに `|` を使い、値内の `/` (URL 等) と衝突しないようにする
sed -i '' -E "s|^const BRAND_NAME = \".*\";|const BRAND_NAME = \"${BRAND_NAME_VALUE}\";|" "${MAIN_JS}"

# supabase_url
if [ -z "${SUPABASE_URL_VALUE}" ]; then
  echo "${LOG_PREFIX} WARN: secrets.yaml に supabase_url が無い。main.js の既存値を維持。"
else
  echo "${LOG_PREFIX} SUPABASE_URL を同期"
  sed -i '' -E "s|^const SUPABASE_URL = \".*\";|const SUPABASE_URL = \"${SUPABASE_URL_VALUE}\";|" "${MAIN_JS}"
fi

# supabase_anon_key
if [ -z "${SUPABASE_ANON_KEY_VALUE}" ]; then
  echo "${LOG_PREFIX} WARN: secrets.yaml に supabase_anon_key が無い。main.js の既存値を維持。"
else
  echo "${LOG_PREFIX} SUPABASE_ANON_KEY を同期"
  sed -i '' -E "s|^const SUPABASE_ANON_KEY = \".*\";|const SUPABASE_ANON_KEY = \"${SUPABASE_ANON_KEY_VALUE}\";|" "${MAIN_JS}"
fi

# --- wrangler でデプロイ ---
# commit-message は ASCII 固定 (日本語コミットメッセージは wrangler/Cloudflare 側で文字化け
# やエラーを誘発することがあるため)
COMMIT_MSG="deploy dashboard from local script $(date -u +%Y-%m-%dT%H:%M:%SZ)"

if command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD="wrangler"
else
  WRANGLER_CMD="npx --yes wrangler@latest"
fi

echo "${LOG_PREFIX} ${WRANGLER_CMD} でデプロイ中..."
cd "${PROJECT_ROOT}"
$WRANGLER_CMD pages deploy ./dashboard \
  --project-name yakiimo-temp-monitor \
  --commit-message "${COMMIT_MSG}"
