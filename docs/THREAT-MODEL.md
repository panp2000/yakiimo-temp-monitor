# Threat Model — yakiimo-temp-monitor

本文書は yakiimo-temp-monitor の脅威モデルを **実装ベース** で記述する。資産・防御層・既知の限界・インシデント対応手順を、ファイル/行番号と紐付けて記述している。設計思想や運用環境の概要は `README.md` と `docs/DEPLOY.md` にあるため、本文書では脅威・防御・限界・rotation 手順に焦点を絞る。

## Asset & secret inventory

| Secret / Asset | 値の所在 | git 管理外の根拠 | 用途 | rotation 主体 |
|---|---|---|---|---|
| `INGEST_HMAC_SECRET` | (a) Cloudflare Worker secret store — `worker/wrangler.toml:7` 参照、`wrangler secret put` で投入。(b) ESP32 firmware (literal 焼込) — `firmware-esphome/yakiimo.yaml:297` で `${ingest_hmac_secret}` substitution。元値は `firmware-esphome/secrets.yaml` | `.gitignore:2` で `firmware-esphome/secrets.yaml` 除外 | ESP32 → Worker 間 HMAC-SHA256 共有秘密 (`contract/src/envelope.ts:32-46` の `signEnvelope` で署名生成、`worker/src/index.ts:46-54` で検証) | オーナー (Worker 側 `wrangler secret put` + ESP32 OTA 再書込み) |
| `SUPABASE_SERVICE_ROLE_KEY` | (a) Cloudflare Worker secret (`worker/src/index.ts:9-12` の `Env`)。(b) admin HTML 内 `[ADMIN_SUPABASE_SERVICE_ROLE_KEY]` placeholder を `dashboard/build.sh:73-74` が CF Pages env から置換し inline 埋込 | admin HTML 出力先は `${ADMIN_FILENAME}.html` で生成され、`.assetsignore` に template 自体を除外 (`docs/DEPLOY.md:70`)。CF Pages env は repo 外管理 | (a) Worker → Supabase の `service_role` 認証 (`worker/src/index.ts:97-98`)。(b) admin 画面で RLS bypass セッション操作 | オーナー (Supabase Dashboard で rotation) |
| `SUPABASE_ANON_KEY` (= public) | dashboard `main.js` 内 `const SUPABASE_ANON_KEY` (`dashboard/build.sh:46` で env から置換) | `.gitignore:3` で `dashboard/main.js` 除外、`main.js.example` のみコミット | Live dashboard JS が Supabase REST へ SELECT 発行 | オーナー (Supabase Dashboard、ただし anon key は公開前提のため rotation の意義は限定的) |
| `ADMIN_FILENAME` | CF Pages env var (Production scope)。`dashboard/build.sh:62-83` が値の有無で admin ファイル生成を分岐 | env のみ、repo 内に値は存在しない | admin URL の "obscure path" を構成 | オーナー (CF Pages env var 変更 + 再 deploy) |
| WiFi credentials (`wifi_password_home` 等) | `firmware-esphome/secrets.yaml` (例: `secrets.yaml.example:14-20`) | `.gitignore:2` | ESP32 の WiFi 接続 | オーナー (secrets.yaml 編集 + `esphome run`) |
| `web_password` (ESPHome Web UI Basic 認証) | `firmware-esphome/secrets.yaml` (`secrets.yaml.example:35-36`) | `.gitignore:2` | LAN 内 ESPHome Web UI のアクセス制御 | オーナー (同上) |
| `ota_password` (ESP32 OTA password) | `firmware-esphome/secrets.yaml` (`secrets.yaml.example:30`) | `.gitignore:2` | ESPHome OTA 更新の認可 | オーナー (同上) |
| `fallback_password` (AP モード) | `firmware-esphome/secrets.yaml` (`secrets.yaml.example:25`) | `.gitignore:2` | WiFi 失敗時の captive portal AP 認証 | オーナー (同上) |
| Cloudflare account | CF dashboard | repo 外 | Worker / Pages / Access policy 管理 | オーナー (CF account) |
| Supabase account | Supabase dashboard | repo 外 | DB / Auth / pg_cron / RLS 管理 | オーナー (Supabase account) |

その他、`firmware-esphome/contract.generated.h` は `.gitignore:45` で除外、`worker/.wrangler/` および `.wrangler/` は `.gitignore:19-22` で除外。

## Trust boundaries

```
+--------+   HTTPS(POST,HMAC) +-----------------+ HTTPS(service_role) +----------+
| ESP32  | ─────────────────▶ | Cloudflare      | ──────────────────▶ | Supabase |
|        |    /ingest         | Worker          |                     | (RLS,    |
|        |    X-Yakiimo-{Ts,  | yakiimo-ingest  |                     |  trigger)|
|        |    Sig}            |                 |                     |          |
+--------+                    +-----------------+                     +-----+----+
   ▲                                                                        │
   │ LAN(mDNS,Basic auth)                                                   │
   │                                                                        │ HTTPS (anon key)
   │                                                                        │ + RLS
   │                                              +----------------+        │
   │                                              | Live dashboard | ◀──────┤
   │                                              | (anon, public) |        │
+--+------------+                                 +----------------+        │
| Owner (LAN)   |                                                           │
| Owner (CF/SB  |    HTTPS + CF Access auth        +----------------+       │
| dashboards)   | ───────────────────────────────▶ | Admin (obscure | ◀─────┘
+---------------+                                  | URL, service_role inline)
                                                   +----------------+
```

各 boundary で何が verified / trusted されるか:

- **ESP32 → Worker**: TLS で transport を保護 (ただし `firmware-esphome/yakiimo.yaml:113` で `verify_ssl: false` ゆえ証明書検証なし、MITM 攻撃に対して TLS の機密性のみ保証され integrity は HMAC で代替)。Worker 側は `INGEST_HMAC_SECRET` 一致と timestamp tolerance (past 300s / future 60s, `contract/src/envelope.ts:16-17`) で要求を認証する。
- **Worker → Supabase**: `service_role` の bearer (`worker/src/index.ts:97-98`)。Supabase は service_role を信頼し RLS を bypass する。ただし BEFORE INSERT trigger (`supabase/migrations/008_use_contract_functions.sql:71-73`) は service_role でも escape 不能。
- **Browser (Live dashboard) → Supabase**: anon key + RLS。anon は `is_public = true` のセッション logs のみ読める (`supabase/migrations/004_create_yakiimo_sessions.sql:174-182`)。
- **Browser (admin) → Supabase**: CF Access auth で URL gate を通過した後、HTML 内 inline の service_role で全件操作可。Access が backstop、obscure URL が一次防御。

## Attacker capabilities

### A1. ネットワーク観測者 (TLS 未破壊)

- できること: HTTPS 経路上で送受信のサイズ・宛先 IP を観測。dashboard URL 訪問の事実を把握。
- できないこと: TLS 内部の payload / HMAC secret / anon key / service_role key の取得。
- 検知手段: なし (pasive 観測ゆえ)。

### A2. 物理 ESP32 アクセス

- できること:
  - JTAG / serial 経由で flash dump → firmware binary 抽出 → strings 検索で `INGEST_HMAC_SECRET` literal を取得 (`firmware-esphome/yakiimo.yaml:297` の `"${ingest_hmac_secret}"` は yaml 解析時に literal 展開され、ファームに焼込まれる。`secrets.yaml.example:65-67` のコメントが明記)。
  - WiFi 認証情報、OTA password、Web UI Basic password の抽出 (同様に flash 内に literal)。
  - ESP32 を撤去・解析の上、Worker に既存 secret で偽データを送り続ける。
  - centos 域内範囲のセンサー値 (`-50≤temp_c≤1500` 等) を満たす偽データなら DB 投入される。
- できないこと: Supabase service_role の取得 (ESP32 上には存在しない)。Worker secret 単独 rotation 後の偽装継続。
- 検知手段: ESP32 の物理紛失・盗難の発覚をオーナーが把握すること自体が前提。Worker logs (`worker/wrangler.toml:11-12` の `[observability]`) で異常な device_id / session_id パターンの目視。

### A3. 公開リポ閲覧者

- できること: `secrets.yaml.example`, `main.js.example`, migration ファイル全文、Worker source、ESPHome yaml の literal 構造、admin template の構造を全て閲覧。RLS ポリシー、validation regex、HMAC scheme を完全把握。
- できないこと: secrets.yaml / main.js / 生成済 admin HTML / Worker secret store / CF Pages env / Supabase keys の取得 (`.gitignore:1-5` で除外)。`ADMIN_FILENAME` 値の取得。
- 検知手段: なし (公開情報の閲覧ゆえ)。

### A4. INGEST_HMAC_SECRET 漏洩

- できること: Worker `/ingest` に対し、`SUPPORTED_VERSIONS` (現状 `[1]`, `contract/src/envelope.ts:11`) のいずれかで合致する署名付きリクエストを構築可。timestamp tolerance 内であれば認証通過し、Worker は payload validation (`worker/src/index.ts:77-90`) と DB trigger (008) で値域に収まる限り任意の `device_id` / `session_id` / 値を投入できる。
- できないこと: Supabase の SELECT を anon 制限 (`is_public=true`) を超えて読むこと、RLS / trigger を超えて契約違反値を投入すること、ESP32 firmware を改竄すること。
- 検知手段: Worker logs (`console.log` ingest OK / `console.warn` envelope rejected, `worker/src/index.ts:55,85,110`)。Supabase 側で予期せぬ device_id / session_id / 異常な投入頻度の監視。

### A5. SUPABASE_SERVICE_ROLE_KEY 漏洩

- できること: Supabase REST に直接 service_role bearer で全テーブル CRUD 実行。RLS は完全 bypass。`yakiimo_sessions.is_public` 自由操作、過去 logs 削除、`brand_name` 読取り、cron job 改竄 (pg_cron は SQL 経由)。ただし BEFORE INSERT trigger (`supabase/migrations/008_use_contract_functions.sql:71-73`) は service_role に対しても発火し、契約違反値の INSERT は弾かれる (`raise exception ERRCODE 23514`)。
- できないこと: 契約違反値の INSERT (channel domain 外、device_id 形式違反、measured_at 範囲外、値域外)。Cloudflare 側の secret rotation。
- 検知手段: Supabase Dashboard の API 使用量、活動ログ。`SUPABASE_SERVICE_ROLE_KEY` 漏洩経路の特定 (Worker secret store、admin HTML 等)。

### A6. ADMIN_FILENAME 漏洩 + Cloudflare Access bypass 不能

- できること: admin URL の存在を知るのみ。アクセスは CF Access の auth wall で阻まれる。
- できないこと: admin HTML の中身を取得すること (CF Access 通過なしには 200 が返らない)。
- 検知手段: CF Access logs (誰が auth challenge に到達したか)。

注: CF Access 設定が誤っており admin path が unauth 通過した場合、HTML 内 inline の service_role が露出する。これは A5 に直結する深刻な fallout になる。Access policy の path matching 設定が ADMIN_FILENAME と整合していることを deploy 後に必ず確認する必要がある (本リポでは Access policy は CF dashboard 側管理のため repo に値は存在しない)。

### A7. Cloudflare アカウント侵害

- できること: Worker secret 全閲覧 (INGEST_HMAC_SECRET, SUPABASE_SERVICE_ROLE_KEY)、Pages env var 全閲覧 (BRAND_NAME, ADMIN_FILENAME, SUPABASE_SERVICE_ROLE_KEY)、Access policy 改竄、Worker code 差替え。
- できないこと: Supabase 側 rotation の阻止 (別 account)。
- 検知手段: CF dashboard の audit log、未知の secret 編集履歴。

### A8. Supabase アカウント侵害

- できること: 全テーブル CRUD、RLS / trigger / cron job 改竄、anon / service_role key の rotation、データ全削除、DB 全 dump。
- できないこと: Cloudflare 側の rotation (別 account)。
- 検知手段: Supabase dashboard の audit log。

## Defense layers

### L1 HMAC envelope (Worker)

検証内容:
- `X-Yakiimo-Timestamp` / `X-Yakiimo-Signature` ヘッダ存在 (`worker/src/index.ts:29-33`)。
- timestamp が past 300s / future 60s 以内 (`contract/src/envelope.ts:16-17, 70-74`)。
- HMAC-SHA256 が `${version}\n${timestamp}\n${body}` (`contract/src/envelope.ts:23-25`) と一致。`SUPPORTED_VERSIONS` (`contract/src/envelope.ts:11`) を順次試行 (`contract/src/envelope.ts:90-94`)。
- 失敗時の error code は `signature_mismatch` / `timestamp_out_of_range` のみで、version 単独の不一致は signature_mismatch に丸める (攻撃者に supported version 一覧を渡さないため、`contract/src/envelope.ts:65-66`)。

検証範囲外: ESP32 個体識別 (どの ESP32 が送信したかは secret 1 個では区別できない)。

### L2 Payload validation (Worker)

検証内容:
- body が JSON array (`worker/src/index.ts:74-76`)。
- 各要素を `validateLogRow` (`contract/src/payload.ts:49-91`) で検証:
  - `device_id` regex `^[a-z0-9_-]{1,32}$` (`contract/src/payload.ts:12`)
  - `session_id` regex `^[a-zA-Z0-9_-]{1,64}$` (`contract/src/payload.ts:13`)
  - `measured_at` ISO 8601 UTC (`Z` 終端) (`contract/src/payload.ts:93-95`)
  - `channel` 5 値ドメイン (`contract/src/payload.ts:3-9`)
  - `temp_c` ∈ [-50, 1500] / null (`contract/src/payload.ts:15`)
  - `humidity_pct` ∈ [0, 100] / null
  - `pressure_hpa` ∈ [800, 1200] / null
- 違反は 422 で details JSON を返す (`worker/src/index.ts:84-90`)。

検証範囲外: 値の物理的妥当性 (`temp_c=1499` は受け入れられる)。`measured_at` の Worker 側時計差分 (Worker 上では文字列としてしか見ていない、L3 で SQL `now()` と比較される)。

### L3 BEFORE INSERT trigger (DB)

検証内容: `internal.yakiimo_temp_logs_validate` (`supabase/migrations/008_use_contract_functions.sql:24-61`) が `internal.yakiimo_valid_*` 関数 (`supabase/migrations/007_contract_functions.sql:14-62`) を順次呼び、L2 と同一規則を SQL で再評価。`measured_at` は SQL `now() - interval '1 day'` / `now() + interval '1 hour'` で再評価 (`supabase/migrations/007_contract_functions.sql:35-41`)。

範囲: 全ロール (service_role 含む)。BEFORE INSERT のみ (UPDATE は対象外、`supabase/migrations/008_use_contract_functions.sql:66-73`)。

検証範囲外: UPDATE / DELETE 経路。重複 INSERT (idempotency なし)。

### L4 RLS (anon: SELECT 限定 / service_role: bypass)

`yakiimo_temp_logs`:
- INSERT: anon ポリシー無し (`supabase/migrations/006_drop_anon_insert.sql:24` で撤去)。anon INSERT は暗黙拒否。
- SELECT: anon は `is_public=true` セッションの logs のみ (`supabase/migrations/004_create_yakiimo_sessions.sql:174-182`)。
- UPDATE / DELETE: anon `RESTRICTIVE USING (false)` で deny (`supabase/migrations/003_harden_rls.sql:58-72`)。

`yakiimo_sessions`:
- SELECT: anon は `is_public=true` のみ (`supabase/migrations/004_create_yakiimo_sessions.sql:150-154`)。
- INSERT/UPDATE/DELETE: anon `RESTRICTIVE WITH CHECK (false) / USING (false)` (`supabase/migrations/004_create_yakiimo_sessions.sql:156-161`)。

排他保証: `yakiimo_sessions_single_public_idx` partial unique index (`supabase/migrations/004_create_yakiimo_sessions.sql:65-66`) + `internal.enforce_single_public_session` BEFORE トリガ (`supabase/migrations/004_create_yakiimo_sessions.sql:104-122`) の二重で「同時 is_public=true は 1 件のみ」を保証。

### L5 Cloudflare Access (admin URL)

admin HTML は `${ADMIN_FILENAME}.html` として生成され (`dashboard/build.sh:62-83`)、CF Access policy (CF dashboard 側管理) で auth wall を構成。inline `<meta name="robots" content="noindex, nofollow">` (`dashboard/admin.template.html:6`) で検索エンジン索引を抑止。

検証範囲外: CF Access policy の設定そのもの (repo 内に値は存在しない、CF dashboard で確認が必要)。

### L6 Obscure URL (admin filename env-driven)

`ADMIN_FILENAME` env が deploy 時に admin ファイル名を決定する (`dashboard/build.sh:62-83`)。値は repo 外。L5 の Access wall が一次防御で、本層は二次的な obscurity。

検証範囲外: env 漏洩経路 (CF dashboard 侵害、CI/CD log の出力等)。

### L7 pg_cron auto-close (運用上の保険)

`yakiimo_auto_close_idle_sessions` (5 分毎、`supabase/migrations/005_setup_auto_close_cron.sql:45-55`) が `ended_at < now() - interval '30 minutes'` の `is_public=true` セッションを `is_public=false` に flip。オーナーの「焼成終了後に手動で false に戻し忘れ」をカバー。

検証範囲外: live セッションが意図せず public のまま残った直後 (最大 30 分間 + cron 実行間隔 5 分の遅延) のデータ。

## Honest gaps

実装上、以下は防御の範囲外。観測されていない範囲については「観測されていない、要確認」と明記する。

1. **ESP32 物理抽出による HMAC secret 漏洩 (A2)**: ESP32 flash dump で `INGEST_HMAC_SECRET` literal を抽出可能。NVS 暗号化 / secure boot は本リポ実装上設定されていない (`firmware-esphome/yakiimo.yaml` 内に `flash_encryption` / `secure_boot_v2` の設定なし)。
2. **ESP32 firmware 改竄による「契約内偽データ」送信 (A2 / A4)**: Worker / DB は値域・形式しか検証しない。`temp_c=1499`, `channel='env'`, `device_id='esp32-01'` は全層で受理される。実温度との突合は不能。
3. **TLS 証明書検証なし (ESP32 → Worker)**: `firmware-esphome/yakiimo.yaml:113` で `verify_ssl: false`。同コメントに「CA 固定は後追い改善」とあり未実装。完全な TLS MITM 攻撃下でも HMAC が integrity を担保するため payload 改竄は防げるが、攻撃者が観測する body は平文に近い (TLS encryption は機能するが endpoint validation がないため、攻撃者は CA 偽装で session key を握れる)。
4. ~~**リプレイ攻撃による重複 INSERT**~~ — **Phase 14-A (`supabase/migrations/009_add_unique_constraint.sql`) で対処済**。`yakiimo_temp_logs` に `(device_id, session_id, channel, measured_at)` UNIQUE 制約 + Worker の `Prefer: resolution=ignore-duplicates` (`worker/src/index.ts:99`) で同一 measurement の重複 POST は silent OK 扱い、行は重複しない。なお HMAC envelope 自体の重複検証は依然行わないため、攻撃者の "資源消費攻撃" (大量重複 POST で Worker / DB 負荷を上げる) は別 gap として gap 5 (DDoS) で扱う。
5. **DDoS / availability**: Cloudflare Free tier (Worker 1日 100k req)、Supabase Free tier の制限到達でサービス停止可能。Worker / DB に rate limit / per-device quota は実装されていない。
6. **公開ダッシュボード経由の business intelligence 推測**: `BRAND_NAME` (`dashboard/build.sh:31` の env)、営業時間 (live セッションの存在パターン)、温度プロファイル (チャンネル時系列) が anon 経路で公開される。検索エンジンで `BRAND_NAME` から実店舗位置・スケジュール推定可。
7. **CF Access policy の path matching ミス**: admin URL の Access policy が ADMIN_FILENAME と整合していない場合、admin HTML 内の service_role が unauth 公開される。本リポ実装からは CF dashboard 側設定の正しさを検証できない (要 CF dashboard 確認)。
8. **anon key を組込んだ Live dashboard JS 配布範囲**: `dashboard/main.js` 内の `SUPABASE_ANON_KEY` は CF Pages から無認証配信される。anon key は public 前提だが、key 単体で `yakiimo_sessions` の `is_public=false` 行 SELECT を試す bot に対しては RLS で stop。
9. **OTA password / Web UI Basic password の強度**: `secrets.yaml.example:30-36` の例値はそのまま運用すれば弱い。LAN 内攻撃者が OTA で任意 firmware を書き込めば INGEST_HMAC_SECRET 含む全 secret が抽出される。実運用での強度は repo 外管理の `secrets.yaml` 値次第。
10. **`web_server.auth` Basic 認証は HTTP**: ESPHome の `web_server` (`firmware-esphome/yakiimo.yaml:73-78`) は LAN 内 HTTP。同一 LAN 上で sniff 可能。
11. **`measured_at` の clock skew 攻撃**: `MEASURED_AT_PAST_INTERVAL = '1 day'` (`contract/src/payload.ts:22`) と緩く、過去 24 時間のリプレイは tolerance 内であれば成立する (上記 4 と組合せ)。
12. **admin HTML 配下の Chart.js / date-fns CDN 依存**: `dashboard/admin.template.html:33-34` は `cdn.jsdelivr.net` を直接読込。CDN 改竄で admin にも影響するが、CF Access の auth wall 内で実行されるためアクセスは限定。

## Incident response (rotation 手順)

各 secret leak / インシデントごとの具体手順。コマンドはオーナー LAN PC 上前提。

### INGEST_HMAC_SECRET 漏洩

1. 新 secret を生成: `openssl rand -hex 32` → 出力を退避。
2. Worker secret 更新: `cd worker && npx wrangler secret put INGEST_HMAC_SECRET` → 1 で得た値を貼付。
3. ESP32 firmware 更新: `firmware-esphome/secrets.yaml` の `ingest_hmac_secret` を新値に書換 → `cd firmware-esphome && esphome run yakiimo.yaml` で OTA 書込み (全 ESP32 個体)。
4. 切替確認: Worker logs で旧 secret の signature_mismatch エラーが立った後、新 secret で OK が出ることを確認 (`worker/src/index.ts:55, 110`)。
5. 旧 secret は退避ファイルから削除。

注: Worker と ESP32 は同時切替が不可 (atomic rotation できない)。ESP32 OTA 中は `signature_mismatch` で ingest が一時失敗する可能性があるため、焼成セッション中の rotation は避ける。

### SUPABASE_SERVICE_ROLE_KEY 漏洩

1. Supabase Dashboard → Project Settings → API → "Reset service_role key"。新 JWT を退避。
2. Worker secret 更新: `cd worker && npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY` → 新値を貼付。
3. CF Pages env 更新: CF dashboard → Pages project → Settings → Environment variables → Production scope の `SUPABASE_SERVICE_ROLE_KEY` を新値に。
4. admin 再 build: CF Pages の deploy を trigger (空 commit push か CF dashboard の "Retry deployment")。`dashboard/build.sh:73-74` が新値を埋め込む。
5. 確認: Worker `console.error` の `supabase upstream error` (`worker/src/index.ts:106-107`) が出ていないこと、admin 画面でセッション一覧が読めること。

### SUPABASE_ANON_KEY 漏洩

公開 key ゆえ rotation の意義は限定的だが、新規 anon key を発行することで漏洩 key を使い続ける bot を切ることはできる。

1. Supabase Dashboard で anon key を rotation。
2. CF Pages env `SUPABASE_ANON_KEY` を更新 → 再 deploy (`dashboard/build.sh:46` で `main.js` に置換)。
3. ESPHome の `secrets.yaml` 内 `supabase_anon_key` (`secrets.yaml.example:44`) は Phase 8 以降は ingest 経路から外れているが、`firmware-esphome/yakiimo.yaml:23` で substitution として残存。実害はないが整合性のため更新推奨 → `esphome run`。

### ADMIN_FILENAME 漏洩

CF Access auth が backstop で守るが、二重防御を回復するため:

1. CF Pages env `ADMIN_FILENAME` を別値に更新。
2. CF Access policy の path matching を新 filename に更新 (CF dashboard)。
3. CF Pages 再 deploy → 新 filename の HTML が出る。旧 filename の HTML は `npx wrangler deploy` の差分で配信から消える (要確認: 観測されていないため、deploy 後に旧 URL が 404 を返すことを必ず確認)。

### ESP32 紛失 / 物理盗難

ESP32 内蔵の `INGEST_HMAC_SECRET` で偽データ送信が可能になる。

1. INGEST_HMAC_SECRET rotation (上記手順)。これで盗難個体からの ingest を遮断。
2. 残存 ESP32 全数を OTA 書込みで新 secret に同期 (`esphome run yakiimo.yaml`)。
3. Supabase 側で盗難前後の異常データを確認。必要なら `yakiimo_temp_logs` の対象 session_id を service_role 経由で削除。
4. WiFi password / OTA password / web Basic password も同 ESP32 内の literal として漏洩しうるため、`secrets.yaml` 内全項目の rotation を推奨。

### Worker / Supabase アカウント侵害疑い

1. Worker secret 全 rotation: `cd worker && npx wrangler secret list` で現在の secret 名を確認、`SUPABASE_URL` 以外の機密 (INGEST_HMAC_SECRET, SUPABASE_SERVICE_ROLE_KEY) を上記手順で更新。
2. Supabase service_role + anon key rotation (Supabase dashboard)。
3. CF / Supabase の audit log を遡及確認、未知の secret 編集・policy 変更・data export がないか調査。
4. Cloudflare Access policy (admin URL) の整合性確認。policy が改竄されていれば修復 + admin filename も rotation。
5. ESP32 firmware 再書込み (新 INGEST_HMAC_SECRET 焼込み)。

## Privacy

公開 dashboard 経由で第三者が推測可能な情報:

- **営業日・営業時間**: live セッションの存在パターンから (`yakiimo_sessions` の `is_public=true` 期間。pg_cron で 30 分 idle 後 false 化)。連日観測すれば営業曜日・時間帯が推定される。
- **屋号・ブランド名**: `BRAND_NAME` env (`dashboard/build.sh:31, 44`) が live dashboard に表示される。
- **焼成プロファイル**: 5 チャンネルの温度時系列。職人ノウハウに直結する温度カーブが第三者に観測される。
- **位置情報**: `BRAND_NAME` を検索エンジンで照合すれば実店舗位置・SNS アカウント・営業時間と紐付け可能。

公開 dashboard では露出しないが admin / DB に存在する情報:

- セッション `display_name` / `purpose` / `fire_start_at` / `brix` / `notes` (`supabase/migrations/004_create_yakiimo_sessions.sql:48-60`)。RLS の anon SELECT は `is_public=true` のみ通すが、列レベル制限は無いため `is_public=true` 中のセッションについてはこれらも anon に見える。Live dashboard JS 側で表示しないだけ。
- 過去セッションのメタデータと全 logs (pg_cron auto-close 後は `is_public=false` で anon SELECT 不可、service_role / admin 画面のみ閲覧可)。
- ESPHome Web UI 経由の WiFi SSID / IP (`firmware-esphome/yakiimo.yaml:182-189`) — LAN 内のみ。

## 関連ドキュメント

- Deploy 環境: `docs/DEPLOY.md`
- Ingest Contract 仕様 (auto-generated): `docs/CONTRACT.md`
- ドメイン語彙: `docs/CONTEXT.md`
- 設計判断: `docs/adr/`
- Worker (ingest) 詳細: `worker/README.md`
