# yakiimo-ingest worker

ESP32 → Cloudflare Worker → Supabase の中継 Worker です。HMAC-SHA256 で
ESP32 を認証し、合格時のみ service_role で Supabase REST に転送します。

## デプロイ

```bash
cd worker
npm install
npx wrangler login           # 初回のみ
npx wrangler deploy
```

## Secrets 登録 (初回 / 値変更時)

```bash
npx wrangler secret put SUPABASE_URL
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx wrangler secret put INGEST_HMAC_SECRET
```

`INGEST_HMAC_SECRET` は ESP32 側 `secrets.yaml` の `ingest_hmac_secret` と
同じ値にしてください。

## 動作確認

```bash
SECRET="<INGEST_HMAC_SECRET>"
TS=$(date +%s)
BODY='[{"device_id":"esp32-01","session_id":"test-8a","measured_at":"2026-05-06T15:00:00Z","channel":"env","temp_c":20.0,"humidity_pct":null,"pressure_hpa":null}]'
SIG=$(printf "%s\n%s" "$TS" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')

curl -X POST "https://yakiimo-ingest.<account>.workers.dev/ingest" \
  -H "Content-Type: application/json" \
  -H "X-Yakiimo-Timestamp: $TS" \
  -H "X-Yakiimo-Signature: $SIG" \
  -d "$BODY"
# → 201 Created を期待
```

認証エラー時の挙動:

- 必須ヘッダ欠落 / timestamp が範囲外 / HMAC 不一致 → `401`
- `Content-Type` が `application/json` でない → `415`
- body が空 → `400`
- Supabase 側エラー → `502`

## ログ

```bash
npx wrangler tail
```

Worker ダッシュボードからも確認できます (`[observability] enabled = true`)。
