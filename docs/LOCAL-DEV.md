# Local development guide — yakiimo-temp-monitor

ESP32 ハードウェア無しでも yakiimo-temp-monitor の core 開発を回す手順。本文書は **すでに setup された開発機 (Mac / Linux + Node 22)** を前提とする。クリーンインストールは `README.md`、実 deploy 経路は `docs/DEPLOY.md`、ハードウェア込みの動作確認は `README.md` の「動作確認の流れ」節を参照。本文書は **local-only / hardware-less** 経路に特化する。

## 前提

- Node.js 22 以降 (Cloudflare Worker と互換)
- npm 10 以降 (root が npm workspaces 構成 — `package.json` で `contract`, `dashboard-shared`, `worker` を束ねている)
- Git
- (任意) ESPHome 本体 — firmware の YAML を local で syntax check したい場合のみ
- (任意) Supabase CLI — local Postgres / REST stack で E2E を回したい場合のみ

## 1. リポ全体の依存解決

リポルートで一度実行すれば、全 workspace (`contract`, `dashboard-shared`, `worker`) の依存が解決される。

```bash
cd <リポルート>
npm install
```

確認:
- `node_modules/` 直下に `wrangler` binary が立つこと (root devDep。`docs/DEPLOY.md` の「root の wrangler.toml と wrangler devDep は意図的に repo 側にある」節参照)
- `node_modules/@yakiimo/contract` 等が各 workspace への symlink になっていること (`@yakiimo/dashboard-shared` も同様)

## 2. Contract / dashboard-shared のユニットテスト

Pure logic は workspace ごとに vitest で完結する。ハードウェア / Supabase 接続不要。

```bash
# Contract (envelope HMAC + payload validation)
cd contract && npm run test
# → contract/test/envelope.test.ts, payload.test.ts が走る

# Dashboard-shared (median3Filter + buildDatasets + channel メタデータ)
cd dashboard-shared && npm run test
# → dashboard-shared/test/channels.test.ts, datasets.test.ts, median.test.ts が走る
```

watch モード: 各 workspace で `npm run test:watch` (vitest watch)。

## 3. TypeScript 型検証

各 workspace で `npm run typecheck` (= `tsc --noEmit`):

```bash
cd contract && npm run typecheck
cd dashboard-shared && npm run typecheck
cd worker && npm run typecheck
```

worker は `@yakiimo/contract` を symlink で参照しているので、contract 側の型変更が直ちに worker に伝搬する。

## 4. Worker (yakiimo-ingest) のローカル動作

`worker/wrangler.toml` で定義された ingest Worker を local server として起動できる。

```bash
cd worker
npx wrangler dev
# デフォルト http://localhost:8787 で listen、Ctrl+C で停止
```

`wrangler dev` は **production secrets を参照しない**。必要な env は 3 つ (`worker/wrangler.toml` のコメントに記載):

- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `INGEST_HMAC_SECRET`

ローカル起動時はシェル env 経由で stub を注入する:

```bash
cd worker
SUPABASE_URL="https://stub.supabase.co" \
SUPABASE_SERVICE_ROLE_KEY="dev-stub" \
INGEST_HMAC_SECRET="dev-only-hmac-secret" \
npx wrangler dev
```

注: `SUPABASE_URL` に stub を渡した状態では `worker/src/index.ts` 末尾の `fetch(${SUPABASE_URL}/rest/v1/yakiimo_temp_logs, ...)` が失敗するため Worker は 502 を返す。Worker 単体で envelope (Layer 1, HMAC + timestamp) と payload (Layer 2, LogRow validation) の通過を確認したいだけなら、502 が出ても **検証層は通っている** と読み取れる (Worker のログに `ingest OK version=...` が出る前に upstream で落ちる場合は payload まで通った証跡)。E2E まで通したい場合は section 7 の Supabase local stack を立てる。

## 5. ESP32 を mock した HMAC 付き POST

real device 不要で Worker 経路全体を叩ける。`contract/src/envelope.ts` の `signEnvelope` を Node から呼んで signature 付き fetch を投げる。

```javascript
// 例: scripts/mock-ingest.mjs (この script はリポにコミットされていない。
// ローカルに作る場合は scripts/ 配下が便利。コミットせず手元 only でも可)
import { signEnvelope } from "../contract/src/envelope.ts";
// または: import { signEnvelope } from "@yakiimo/contract/envelope";

const SECRET = process.env.INGEST_HMAC_SECRET || "dev-only-hmac-secret";
const TS = Math.floor(Date.now() / 1000);
const body = JSON.stringify([
  {
    device_id: "esp32-mock-01",
    session_id: "mock-2026-05-07",
    measured_at: new Date().toISOString(),
    channel: "potato_internal",
    temp_c: 120.5,
    humidity_pct: null,
    pressure_hpa: null,
  },
]);
const sig = await signEnvelope(SECRET, TS, body);

const res = await fetch("http://localhost:8787/ingest", {
  method: "POST",
  headers: {
    "Content-Type": "application/json",
    "X-Yakiimo-Timestamp": String(TS),
    "X-Yakiimo-Signature": sig,
  },
  body,
});
console.log(res.status, await res.text());
```

実行: TypeScript ファイルを直接 import するため `tsx` が必要 (`contract/devDependencies` に既に入っている):

```bash
npx tsx scripts/mock-ingest.mjs
# あるいは contract dir 内で実行する場合は import path を相対調整
```

期待動作 (envelope + payload validation のみ確認したい場合):
- HMAC が正しい → Worker のログに `ingest OK version=1 ...` (ただし Supabase が stub だと直後に 502 になる)
- HMAC ずれ → 401 `Invalid signature`
- timestamp が古すぎる/未来すぎる → 401 `Timestamp out of range` (許容範囲: past 300s / future 60s、`contract/src/envelope.ts` の `TIMESTAMP_TOLERANCE_*` 定数)
- payload 不正 → 422 `payload_invalid` JSON

payload 値域は `contract/src/payload.ts` を参照:
- `device_id`: `/^[a-z0-9_-]{1,32}$/`
- `session_id`: `/^[a-zA-Z0-9_-]{1,64}$/`
- `channel`: `potato_internal` | `potato_surface` | `kiln_ambient` | `stone_surface` | `env`
- `temp_c`: -50 〜 1500 (nullable)
- `humidity_pct`: 0 〜 100 (nullable)
- `pressure_hpa`: 800 〜 1200 (nullable)
- `measured_at`: ISO 8601 UTC (`Z` 終端)。Worker 側での past/future ウィンドウ検証は `MEASURED_AT_PAST_INTERVAL = "1 day"` / `MEASURED_AT_FUTURE_INTERVAL = "1 hour"` だが、これは現状 RLS / DB trigger 側で消費される定数で、Worker 自体は値域外でも 422 にはならない (= 値域外でも Worker は accept、Supabase 側で reject される設計)。

## 6. Dashboard のローカル確認

`dashboard/build.sh` は CF Pages / Workers Build から呼ばれる前提だが、必要 env を揃えれば手元でも実行できる。

```bash
cd dashboard
SUPABASE_URL="https://stub.supabase.co" \
SUPABASE_ANON_KEY="dev-anon-stub" \
BRAND_NAME="開発中" \
bash build.sh
```

build.sh が実行する内容 (要点):
1. `npm --workspace=@yakiimo/dashboard-shared run build` で `dashboard-shared/dist/dashboard-shared.js` を esbuild
2. それを `dashboard/dashboard-shared.js` に cp
3. `main.js.example` を `main.js` にコピーし、`SUPABASE_URL` / `SUPABASE_ANON_KEY` / `BRAND_NAME` / `SOCIAL_*` を sed 置換
4. `ADMIN_FILENAME` env が設定されていれば `admin.template.html` から `${ADMIN_FILENAME}.html` を生成 (この場合は `SUPABASE_SERVICE_ROLE_KEY` も必須)

注: 生成物 `dashboard/main.js` と `dashboard/dashboard-shared.js` は root `.gitignore` で ignore されている (build artifact 扱い)。手動で消したい場合はこの 2 ファイルを削除すれば clean な状態に戻る。

### dev server を立てる必要がある

`dashboard/index.html` line 101 に `<script src="/dashboard-shared.js"></script>` という **絶対パス** での読込がある。`file://` でブラウザに開くとファイルシステム root から解決を試みて失敗する。HTTP server を立てる:

```bash
cd dashboard
npx http-server -p 8080 .
# あるいは:
# python3 -m http.server 8080
# http://localhost:8080/ をブラウザで開く
```

これにより `/dashboard-shared.js` は `http://localhost:8080/dashboard-shared.js` として正しく解決される。

実 Supabase に繋がない状態 (`SUPABASE_URL=stub` の場合) では以下が空になる:
- 折れ線チャート (`yakiimo_temp_logs` からの取得失敗)
- ライブ状態表示 / セッション一覧 (`yakiimo_sessions` からの取得失敗)

→ **JS 構文・build artifact・theme 切替・静的レイアウトの確認のみ可能**。データを伴うインタラクションを見たければ section 7 へ。

## 7. End-to-end (local Supabase 含む)

Supabase まで含めて手元で回すには Supabase CLI で local stack を立てる。

```bash
# CLI のインストールは https://supabase.com/docs/guides/cli を参照
supabase init      # 初回のみ (現リポにはコミットされていない、以下注記参照)
supabase start     # local Postgres + Studio + REST 起動
```

立ち上がったら `supabase/migrations/001_*.sql` から `008_*.sql` を順に適用する (Studio の SQL editor で順次実行、または `supabase db reset` で migrations を一括再適用)。Worker dev の `SUPABASE_URL` を local stack の URL に切替えて mock POST を流せば、`yakiimo_temp_logs` への INSERT までを検証できる。

注: 本リポは現状 `supabase/config.toml` などの CLI init 用ファイルを **持っていない** (リポを git ls-files で確認済 — `supabase/migrations/` のみ)。`supabase init` を実行するとカレントに config.toml が生成される。生成物をコミットするかは別途判断 (本文書では推奨しない: deploy 経路は `docs/DEPLOY.md` に記載されている remote Supabase 経路のみが production と整合)。

## 8. ESP32 firmware を実機なしで syntax check

実機書込みなしで yaml の構文確認のみ可能:

```bash
cd firmware-esphome
esphome config yakiimo.yaml
# 期待: "Configuration is valid!"
```

詰まりやすい点:

- **`secrets.yaml` が無いと「!secret xxxx not found」で落ちる**。`secrets.yaml.example` を `secrets.yaml` にコピーし、example 値のまま config check は通る。`firmware-esphome/.gitignore` で `secrets.yaml` は ignore されているので commit されない。**ただしこの secrets.yaml は実機書込みに使ってはならない** (example の placeholder 値のため WiFi にも繋がらないし、INGEST_HMAC_SECRET も dev 用)。
- **`contract.generated.h` も必要**。root `.gitignore` で ignore されている generated artifact なので、初回チェックアウト時には存在しない。事前に生成すること:

  ```bash
  cd <リポルート> && npm run codegen
  # または cd contract && npm run codegen
  # → firmware-esphome/contract.generated.h, supabase/.../*.sql, docs/CONTRACT.md を生成
  ```

`yakiimo.yaml` は `contract.generated.h` の `yakiimo_build_signed_message` / `hmac_helper.h` の `yakiimo_hmac_sha256_hex` を参照して L290 周辺で署名を組み立て、`X-Yakiimo-Timestamp` / `X-Yakiimo-Signature` ヘッダ付きで Worker に POST する。本 helper の C++ 実装は contract module の TS 実装と message format (`${version}\n${timestamp}\n${body}`) を共有しているため、TS 側の単体テスト (section 2) が C++ 側の動作保証も兼ねる。

## 関連ドキュメント

- Deploy 環境: `docs/DEPLOY.md`
- スキーマ: `docs/SCHEMA.md`
- 脅威モデル: `docs/THREAT-MODEL.md`
- Ingest Contract 仕様: `docs/CONTRACT.md` (auto-generated)
- ドメイン辞書: `docs/CONTEXT.md`
- 動作確認 (実機込み): `README.md` の「動作確認の流れ」節
- Worker 詳細: `worker/README.md`
- Dashboard 詳細: `dashboard/README.md`
