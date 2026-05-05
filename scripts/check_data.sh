#!/bin/bash
# yakiimo_temp_logs の最新行を確認するヘルパー
# Usage:
#   bash scripts/check_data.sh              # デフォルトは最新50行
#   bash scripts/check_data.sh 10           # 最新10行
#   bash scripts/check_data.sh 100 round1   # session_id 指定
#
# 設定読み込み元の優先順位:
#   1. 環境変数 $YAKIIMO_ENV_FILE で指定された .env (KEY=VALUE 形式)
#   2. プロジェクト内 firmware-esphome/secrets.yaml (推奨経路)
#   3. 上記いずれも無ければエラー終了
set -euo pipefail

LIMIT="${1:-50}"
SESSION="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SECRETS_YAML="${PROJECT_ROOT}/firmware-esphome/secrets.yaml"

SUPABASE_URL=""
SERVICE_KEY=""

# 1. $YAKIIMO_ENV_FILE 優先
if [ -n "${YAKIIMO_ENV_FILE:-}" ]; then
  if [ ! -f "${YAKIIMO_ENV_FILE}" ]; then
    echo "ERROR: YAKIIMO_ENV_FILE='${YAKIIMO_ENV_FILE}' not found" >&2
    exit 1
  fi
  SUPABASE_URL=$(grep -E '^SUPABASE_URL=' "${YAKIIMO_ENV_FILE}" | head -1 | cut -d= -f2-)
  SERVICE_KEY=$(grep -E '^SUPABASE_SERVICE_KEY=' "${YAKIIMO_ENV_FILE}" | head -1 | cut -d= -f2-)
  if [ -z "${SUPABASE_URL}" ] || [ -z "${SERVICE_KEY}" ]; then
    echo "ERROR: SUPABASE_URL or SUPABASE_SERVICE_KEY missing in ${YAKIIMO_ENV_FILE}" >&2
    exit 1
  fi
# 2. firmware-esphome/secrets.yaml
elif [ -f "${SECRETS_YAML}" ]; then
  # YAML の `key: "value"` または `key: value` から値を抽出 (引用符は剥がす)
  SUPABASE_URL=$(grep -E '^[[:space:]]*supabase_url:' "${SECRETS_YAML}" | head -1 | sed -E 's/^[[:space:]]*supabase_url:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')
  SERVICE_KEY=$(grep -E '^[[:space:]]*supabase_anon_key:' "${SECRETS_YAML}" | head -1 | sed -E 's/^[[:space:]]*supabase_anon_key:[[:space:]]*//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')
  if [ -z "${SUPABASE_URL}" ] || [ -z "${SERVICE_KEY}" ]; then
    echo "ERROR: supabase_url or supabase_anon_key missing in ${SECRETS_YAML}" >&2
    exit 1
  fi
else
  echo "ERROR: 設定ファイルが見つからない。" >&2
  echo "  - 環境変数 YAKIIMO_ENV_FILE で .env を指定するか" >&2
  echo "  - ${SECRETS_YAML} を用意してください" >&2
  exit 1
fi

QS="select=id,measured_at,session_id,channel,temp_c,humidity_pct,pressure_hpa&order=measured_at.desc&limit=${LIMIT}"
if [ -n "$SESSION" ]; then
  QS="${QS}&session_id=eq.${SESSION}"
fi

URL="${SUPABASE_URL}/rest/v1/yakiimo_temp_logs?${QS}"

RESPONSE=$(curl -sS \
  -H "apikey: ${SERVICE_KEY}" \
  -H "Authorization: Bearer ${SERVICE_KEY}" \
  "$URL")

YAKIIMO_RESPONSE="${RESPONSE}" python3 <<'PYEOF'
import json, os, sys
raw = os.environ.get("YAKIIMO_RESPONSE", "")
try:
    rows = json.loads(raw)
except json.JSONDecodeError:
    print(f"ERROR: 応答を JSON としてパースできなかった: {raw[:200]}", file=sys.stderr)
    sys.exit(1)
if not rows:
    print("(no rows)")
    sys.exit(0)
if isinstance(rows, dict) and "message" in rows:
    print(f"ERROR from Supabase: {rows}", file=sys.stderr)
    sys.exit(1)
print(f"{len(rows)} rows:")
print(f"{'measured_at':<26} {'session':<22} {'channel':<18} {'temp_c':>8} {'humidity':>9} {'pressure':>10}")
print("-" * 100)
for r in rows:
    t = r.get("temp_c")
    h = r.get("humidity_pct")
    p = r.get("pressure_hpa")
    t_str = f"{t:.2f}" if t is not None else "NaN"
    h_str = f"{h:.1f}" if h is not None else "-"
    p_str = f"{p:.1f}" if p is not None else "-"
    print(f"{r.get('measured_at',''):<26} {r.get('session_id',''):<22} {r.get('channel',''):<18} "
          f"{t_str:>8} {h_str:>9} {p_str:>10}")
PYEOF
