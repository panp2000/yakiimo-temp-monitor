# yakiimo-temp-monitor

ESP32 と熱電対 4 本 + 環境センサーで、やきいも(石焼き芋)下焼き工程の温度を 5 チャンネル同時計測し、Supabase に蓄積してブラウザでリアルタイム可視化するオープンハードウェア / オープンソースプロジェクトです。1 セッションあたり約 2 時間の焼成中、芋の内部温度・芋の表面温度・釜内雰囲気温度・石の表面温度・屋外環境(気温/湿度/気圧)を 5 秒間隔で記録します。

## 概要

- ハードウェア: ESP32-DevKitC-32E + MAX31855 × 4 (K 型熱電対 IC) + BME280 (温湿度気圧 I2C)
- ファームウェア: ESPHome ベース (`firmware-esphome/yakiimo.yaml`)
- 中継: Cloudflare Worker (`worker/`) が ESP32 を HMAC-SHA256 で認証し、合格時のみ Supabase へ転送
- データ層: Supabase PostgREST + Row Level Security (anon は SELECT のみ、INSERT/UPDATE/DELETE は service_role 経由)
- 公開ダッシュボード: Vanilla HTML + Chart.js + supabase-js (Cloudflare Pages デプロイ)
- 管理画面: 同じ Pages プロジェクト内に不可視 URL + Cloudflare Access で配置 (オーナーのみ)
- セッション自動 close: pg_cron が 5 分毎に走り、30 分以上 idle のセッションを `is_public=false` に落とす
- サンプリング: 全 5 チャンネル 5 秒統一、5 秒ごとに 5 行を 1 回のバッチ POST
- 計測時間: 1 セッション ≒ 2 時間、データ量 ≒ 14,400 行
- ingest 仕様: Yakiimo Ingest Contract (TypeScript source of truth) を C++ ヘッダ / SQL 関数 / Markdown 仕様書に codegen し、ESP32・Worker・Supabase の 3 者で同一定義を共有

## Yakiimo Ingest Contract

ESP32 → Worker → Supabase 全体を貫く ingest の仕様 (HMAC エンベロープ + 計測ペイロード) を、`contract/` パッケージに TypeScript で 1 箇所定義し、これを唯一の出典 (source of truth) として扱います。ここから C++ ヘッダ・SQL 関数・Markdown 仕様書を機械生成して各層に配布する構成です。詳細は以下を参照してください。

- ドメイン語彙とエンティティ定義: [`docs/CONTEXT.md`](docs/CONTEXT.md)
- Ingest Contract 仕様書 (auto-generated): [`docs/CONTRACT.md`](docs/CONTRACT.md)
- 設計判断の記録 (Architecture Decision Records): [`docs/adr/`](docs/adr/)
- TypeScript 実体: [`contract/src/`](contract/src/) (`envelope.ts`, `payload.ts`)

## Defense in Depth (3 層検証)

ingest リクエストの妥当性検証を 3 層で多重化し、どの層が破られても次の層で止まる構成にしています。

| 層 | 場所 | 役割 | 主な検証 |
|----|------|------|----------|
| L1 | Worker (`contract.envelope`) | 外殻 (HMAC エンベロープ) の検証 | 署名一致 / timestamp の許容窓 / バージョン整合 |
| L2 | Worker (`contract.payload`) | 計測ペイロードの構造検証 | チャンネル数 / 必須フィールド / 型と範囲 |
| L3 | Supabase (BEFORE INSERT trigger) | DB 入口での最終チェック | service_role を含む全ロールに対して L2 と同等の検証を SQL で再適用 |

L1+L2 は Worker が contract モジュールを呼んで実行し、L3 は migrations 007/008 で導入した SQL 関数 + BEFORE INSERT トリガーが担います。Worker をバイパスして直接 Supabase に書こうとしても、L3 で必ず再検証されます。

## アーキテクチャ

```
              +--------------------+
              |  ESP32-DevKitC-32E |
              |   ESPHome firmware |
              +----+----------+----+
                   | SPI       | I2C
      +------------+----+   +--+-----+
      | MAX31855 ×4     |   | BME280 |
      | (K 熱電対)      |   | (温湿圧)|
      +-----------------+   +--------+
                   |
                   | HTTPS POST (5 行 / 5 秒, HMAC-SHA256 署名付)
                   v
      +-------------------------------+
      | Cloudflare Worker (worker/)   |
      | - L1: contract.envelope 検証  |
      | - L2: contract.payload 検証   |
      | - service_role で Supabase へ |
      +---------------+---------------+
                      |
                      | service_role (RLS bypass)
                      v
      +-------------------------------+
      | Supabase                      |
      | - yakiimo_temp_logs           |
      | - yakiimo_sessions            |
      | - L3: BEFORE INSERT trigger   |
      |       (全ロールで再検証)      |
      | - pg_cron で idle 30min close |
      | - anon: SELECT only           |
      +-------+---------------+-------+
              |               |
              | anon          | service_role (CF Access 通過後のみ)
              | (is_public    |
              |  =true のみ)  |
              v               v
   +------------------+  +-----------------------+
   | Live dashboard   |  | Admin (不可視 URL +   |
   | (CF Pages 公開)  |  |  CF Access)           |
   | Chart.js + sb-js |  | セッション編集・公開  |
   +------------------+  |  切替・過去詳細閲覧   |
                         +-----------------------+

   + ESP32 自体の Web UI (LAN 内、mDNS)
     http://yakiimo-temp-monitor.local/
```

## 必要なもの

### ハードウェア

| 部品 | 数量 | 備考 |
|------|------|------|
| ESP32-DevKitC-32E | 1 | 他の ESP32 系でもピン互換なら可 |
| MAX31855 K 型熱電対モジュール | 4 | クローン基板可 (実機はクローン基板で動作確認済) |
| K 型熱電対プローブ | 4 | 芋内部・表面用に細プローブ 2 本、釜内・石表面用に太プローブ 2 本を推奨 |
| BME280 I2C モジュール | 1 | I2C アドレス 0x76 を前提 (SDO を GND に) |
| ブレッドボード + ジャンパ線 | 一式 | |
| 16V 100μF 電解コンデンサ | 1 | 電源デカップリング用 |
| 0.1μF セラミックコンデンサ | 1 | 電源デカップリング用 |
| USB ケーブル + 5V 電源 | 1 | 初回書き込みは PC USB、運用時はモバイルバッテリーを推奨 |

電源について: 安価な 5 口 USB ハブ等のスイッチング電源は BME280 の I2C 初期化を妨げる事例があります。Mac の USB ポートまたはモバイルバッテリーから給電してください。

### アカウント

- Supabase (Free プランで十分)
- Cloudflare アカウント (Workers + Pages、無料枠で十分。管理画面を使う場合は Access も無料枠で可)

### ソフトウェア

- Python 3.9 以上 (ESPHome 実行用)
- ESPHome 2024.x 以降 (本リポジトリは 2026 系の `request_headers:` 新方式で書かれています)
- Node.js 18 以降 + `wrangler` (Worker / Pages デプロイ用)

## セットアップ順序

依存順に並べると以下になります。順番を守らないと ESP32 が POST 先を持たないままビルドされる等の不整合が起きます。

1. Supabase プロジェクト作成 + マイグレーション 001-008 を順番に適用
2. `contract/` の codegen を実行 (C++ ヘッダ / SQL / Markdown を生成)
3. Cloudflare Worker デプロイ (URL を発行)
4. ESP32 ファームウェア書き込み (生成した `contract.generated.h` を include、Worker URL を `secrets.yaml` に転記)
5. Cloudflare Pages デプロイ (公開ダッシュボード)
6. (任意) 管理画面用に Cloudflare Access 設定

## 配線

配線図は [`docs/wiring-diagram.svg`](docs/wiring-diagram.svg) を参照してください。ESP32 のピン割当は本機固有のため、他ボードを使う場合は [`firmware-esphome/yakiimo.yaml`](firmware-esphome/yakiimo.yaml) の `pin:` 指定を読み替えてください。

ESP32 ピン割当:

| ESP32 GPIO | 用途 |
|-----------|------|
| 3V3 / GND | 全モジュールの電源 / グランド |
| GPIO18 | SPI SCK (MAX31855 ×4 で共有) |
| GPIO19 | SPI MISO (MAX31855 ×4 で共有) |
| GPIO5 | MAX31855 #0 CS → `potato_internal` (やきいも内部) |
| GPIO15 | MAX31855 #1 CS → `potato_surface` (やきいも表面) |
| GPIO26 | MAX31855 #2 CS → `kiln_ambient` (釜の雰囲気温度) |
| GPIO27 | MAX31855 #3 CS → `stone_surface` (石の表面温度) |
| GPIO32 | I2C SDA (BME280) |
| GPIO33 | I2C SCL (BME280) |

注意点:

- BME280 は SDO を GND に落として I2C アドレス 0x76 で使用します (SDO を 3V3 にすると 0x77)。
- 16V 100μF + 0.1μF を **ESP32 の電源ピン直近の 3V3/GND レール上** に並列配置します。離れた位置に置くと BME280 の I2C 初期化が不安定になる事例が確認されています。
- 各 MAX31855 の T+/T- 端子間に 10nF (または 22nF) のセラミックコンデンサを 1 個ずつ入れて熱電対入力の差動ノイズを除去します。これがないと熱電対のリード線が周囲機器のノイズを拾い、温度値がガタつきます。
- 熱電対の極性は本機で使用する中華規格 (GB/T) では「赤 = POSITIVE」です。国際規格 (IEC) とは逆なので注意してください。接続後にライターで先端を炙って温度が上がれば正解、下がるなら極性が逆です。

## Supabase セットアップ

1. Supabase で新規プロジェクトを作成します。リージョンは利用地域に近いものを選んでください。
2. Dashboard 左サイドバーの **SQL Editor** で `supabase/migrations/` 配下の SQL を **番号順** に貼り付けて実行します。
   - `001_create_yakiimo_temp_logs.sql` — `yakiimo_temp_logs` 作成 + RLS 有効化
   - `002_add_anon_select.sql` — anon SELECT ポリシー (公開ダッシュボード用)
   - `003_harden_rls.sql` — RLS 強化 (UPDATE/DELETE 不可など)
   - `004_create_yakiimo_sessions.sql` — `yakiimo_sessions` テーブルと公開制御 (`is_public` 排他)
   - `005_setup_auto_close_cron.sql` — pg_cron で idle 30 分のセッションを自動非公開化 (5 分毎)
   - `006_drop_anon_insert.sql` — ESP32 直 INSERT 撤去。以降の INSERT は Worker 経由 (service_role) のみ
   - `007_contract_functions.sql` — Ingest Contract の検証関数 (auto-generated。`contract/` の codegen 出力をそのまま貼る)
   - `008_use_contract_functions.sql` — `yakiimo_temp_logs` に BEFORE INSERT トリガーを張り、L3 検証を全ロールで強制
3. **Project Settings → API** から以下 2 つを控えます。
   - `Project URL` (例: `https://xxxxx.supabase.co`)
   - `anon` `public` key (公開ダッシュボード用、200 文字超の JWT)
   - `service_role` `secret` key (Worker と管理画面用、**漏洩厳禁**)
4. **Project Settings → API → Max Rows** を 1000 から 50000 に引き上げます。ダッシュボードはセッション全期間 (約 14,400 行) を一括取得して表示するため、デフォルトの 1000 行制限では切れます。

`pg_cron` 拡張は migration 005 内で `create extension if not exists pg_cron` しているため、Supabase ダッシュボードでの手動有効化は不要です。

テーブル定義の要点 (詳細は SQL ファイル参照):

| テーブル | 役割 |
|----------|------|
| `yakiimo_temp_logs` | 5ch × 5 秒間隔の生計測値。Worker 経由でのみ INSERT |
| `yakiimo_sessions`  | セッションメタ (display_name / purpose / fire_start / brix / notes / `is_public`)。anon は `is_public=true` のみ SELECT 可 |

## Codegen (Ingest Contract)

`contract/` パッケージは TypeScript で書かれた Ingest Contract から、各層が読み込める成果物を機械生成します。Worker をデプロイする前と ESP32 ファームウェアをビルドする前に必ず実行してください。

```bash
cd contract
npm install
npm test          # contract の単体テスト
npm run codegen   # 3 ファイルを生成
```

生成物と扱い:

| 出力先 | 用途 | git 管理 |
|--------|------|----------|
| `firmware-esphome/contract.generated.h` | ESP32 ファーム (yakiimo.yaml が include) | gitignore (ローカル生成) |
| `supabase/migrations/007_contract_functions.sql` | Supabase の検証関数 (L3 で使用) | commit する (auto-generated と明記) |
| `docs/CONTRACT.md` | 公開仕様書 | commit する (auto-generated と明記) |

`contract/src/` を編集したときは必ず `npm run codegen` を再実行し、SQL と Markdown の差分をレビューしてからコミットしてください。Worker は `contract/` を直接 import するので codegen 不要ですが、ESP32 と Supabase 側は生成物経由のため再走が必要です。

## Cloudflare Worker (ingest)

ESP32 → Worker → Supabase の中継 Worker です。`contract/` パッケージを直接 import し、L1 (`contract.envelope`: HMAC-SHA256 + timestamp) と L2 (`contract.payload`: 構造・型・範囲) の検証を順に行い、両方合格した場合のみ service_role で Supabase REST に転送します。anon INSERT を撤去した代わりに、この Worker が唯一の書き込み経路です。

ESP32 を書き込む前に Worker をデプロイして URL を確定させてください。順序を逆にすると ESP32 の `secrets.yaml` に入れる Worker URL が決まりません。

```bash
cd worker
npm install
npx wrangler login           # 初回のみ
npx wrangler deploy
```

Secrets 登録 (初回 / 値変更時):

```bash
npx wrangler secret put SUPABASE_URL
npx wrangler secret put SUPABASE_SERVICE_ROLE_KEY
npx wrangler secret put INGEST_HMAC_SECRET
```

`INGEST_HMAC_SECRET` はランダム 32 文字以上 (`openssl rand -hex 32` 等) を生成し、ESP32 側 `secrets.yaml` の `ingest_hmac_secret` と完全同値にします。

デプロイ後に発行される URL (例 `https://yakiimo-ingest.<account>.workers.dev`) を控え、次節の `secrets.yaml` の `ingest_worker_url` に転記します。

詳細・動作確認 curl・エラー応答仕様は [`worker/README.md`](worker/README.md) を参照してください。

## ファームウェア (ESP32)

### ESPHome のインストール

```bash
pip install --user esphome
esphome version    # 2024.x.x 以上であること
```

PATH に `esphome` が出てこない場合は `~/.local/bin` を PATH に追加するか `python3 -m esphome` で代用してください。

### secrets.yaml を作成

```bash
cd firmware-esphome
cp secrets.yaml.example secrets.yaml
# エディタで secrets.yaml を開き、以下のキーを実値に書き換える
```

埋めるキー (詳細は [`firmware-esphome/secrets.yaml.example`](firmware-esphome/secrets.yaml.example) のコメント参照):

| キー | 内容 |
|------|------|
| `wifi_ssid_home` / `wifi_password_home` | WiFi の SSID / パスワード |
| `wifi_ssid_tether` / `wifi_password_tether` | 出先用 (iPhone テザリング等)。不要なら home と同じ値で可 |
| `fallback_password` | WiFi 全失敗時に ESP32 が立ち上げる AP `Yakiimo Fallback` のパスワード (8 文字以上) |
| `ota_password` | OTA 書き込み時のパスワード (任意) |
| `web_username` / `web_password` | ESP32 Web UI の Basic 認証 |
| `supabase_url` | Supabase Project URL (末尾に `/` や `/rest/v1` を付けない) |
| `supabase_anon_key` | Supabase anon public key (Web UI 表示用、INSERT には使わない) |
| `ingest_worker_url` | Cloudflare Worker の URL (例 `https://yakiimo-ingest.<account>.workers.dev`、末尾の `/ingest` は YAML 側で付与) |
| `ingest_hmac_secret` | Worker の `INGEST_HMAC_SECRET` と完全同値 |
| `session_id` | 計測セッションのラベル初期値。後で Web UI から変更可で NVS に永続化される |
| `brand_name` | 屋号 / 店名。Web UI とダッシュボードのタイトルに表示される。空欄でも可 |

`secrets.yaml` は `.gitignore` で除外されるためコミットされません。`ingest_hmac_secret` は YAML 解釈時に literal 展開されてバイナリに焼き込まれます。漏洩時は Worker secret と ESP32 を必ず同時にローテーションしてください。

### 初回書き込み (USB)

ESP32 ファームウェアは `contract.generated.h` を include するため、書き込みの前に必ず `contract/` の codegen を一度走らせてください (前述の Codegen セクション参照)。`firmware-esphome/contract.generated.h` が無い状態でコンパイルすると失敗します。

ESP32 を USB ケーブルで PC に接続して:

```bash
cd firmware-esphome
esphome run yakiimo.yaml
```

シリアルポートが自動検出されます (複数あれば対話的に選択)。コンパイルは初回 5〜10 分、以降はキャッシュで 1 分以内です。

### 動作確認

書き込み後、シリアルログに以下のような行が出れば成功です。

- `[I][wifi:xxx]: WiFi Connected!` — WiFi 接続成功
- `[I][time:xxx]: Synchronized time: ...` — NTP 同期成功
- `[I][yakiimo]: ingest POST OK (5 rows)` — Worker への 201 応答 (= Supabase INSERT 成功)

ブラウザで以下にアクセスすると Web UI が開き、Basic 認証ののち全センサーの現在値・WiFi 接続情報・セッション ID・「DB保存」スイッチが表示されます。

```
http://yakiimo-temp-monitor.local/
```

mDNS が解決できない環境では、シリアルログの `IP Address:` 行で IP を確認して直打ちしてください。

「DB保存」スイッチを OFF にすると Worker への POST が止まります (試運転や配線確認用)。

### セッション ID の変更

Web UI の「セッションID」フィールドで編集すると NVS に保存され、再起動後も維持されます。ラウンドごとに変更してください (例: `2026-05-04-round1`, `2026-05-04-round2`)。

### WiFi 切替

家庭網と iPhone テザリングなど 2 系統を `secrets.yaml` に登録しておけば、起動時にスキャンして利用可能なものに自動接続します (`fast_connect: false` 必須、本リポジトリの YAML は設定済)。

### OTA 更新

USB 接続なしに、LAN 内であれば再書き込みできます。

```bash
esphome run yakiimo.yaml
# ESPHome が yakiimo-temp-monitor.local を検出して OTA で書き込む
```

`secrets.yaml` を編集した場合は `esphome upload` ではなく必ず `esphome run` を使ってください。`!secret` と `substitutions:` は YAML 解釈時に静的展開されてバイナリに焼き込まれるため、再コンパイルが必要です。

## ダッシュボード (公開)

公開向け live ダッシュボードは Cloudflare Pages にデプロイします。`yakiimo_sessions.is_public = true` のセッションのみ表示されます。

### Cloudflare Pages 自動デプロイ (推奨)

GitHub リポを Cloudflare Pages に接続すると、main ブランチへの push で自動デプロイされます。

1. Cloudflare Dashboard → Workers & Pages → Create application → Pages → Connect to Git
2. 本リポジトリを選択
3. Build settings:
   - Build command: `cd dashboard && bash build.sh`
   - Build output directory: `dashboard`
4. Environment variables (Production):

   必須:
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
   - `BRAND_NAME`

   管理画面を使う場合は併せて必須 (詳細は次節):
   - `ADMIN_FILENAME`
   - `SUPABASE_SERVICE_ROLE_KEY`

   任意 (未設定時はダッシュボードの SNS / ブログ誘導 CTA が非表示):
   - `SOCIAL_TWITTER`
   - `SOCIAL_INSTAGRAM`
   - `SOCIAL_BLOG`
5. Save and Deploy

[`dashboard/build.sh`](dashboard/build.sh) が `main.js.example` から `main.js` を生成し、env 値を埋め込みます。env 未設定 / プレースホルダ残留はビルド失敗で誤公開を防ぎます。

ローカル確認手順は [`dashboard/README.md`](dashboard/README.md) を参照してください。

### 緊急時の手動デプロイ

GitHub 連携が使えない場合のフォールバック。`secrets.yaml` の値を `main.js` に同期してから `wrangler` でデプロイするスクリプトを同梱しています。

```bash
bash scripts/deploy-dashboard.sh
```

## 管理画面 (Admin)

オーナー専用の管理画面を **不可視 URL + Cloudflare Access** の二重防御で運用します。同じ Pages プロジェクト内に別ファイルとして置き、URL を知る者のみ Access の認証画面に到達できる構成です。

### 機能

- セッション一覧 (公開中・非公開を含む全件)
- `is_public` 切替 (1 セッションのみ公開可、排他は DB 制約で保証)
- セッションメタの編集 (`display_name` / `purpose` / `fire_start` / `notes` / `brix`)
- 過去セッションの詳細閲覧 (anon 公開していない `is_public=false` 含む)

### セットアップ

1. Cloudflare Pages → Settings → Environment variables (Production) に追加:
   - `ADMIN_FILENAME` = `xxxxxxx-admin` 等の推測不可な文字列 (英小文字・数字・ハイフンのみ、拡張子なし)。この値が URL のファイル名に直接入ります。
   - `SUPABASE_SERVICE_ROLE_KEY` = Supabase Project Settings → API → `service_role` `secret` key。**SECRET 扱い**で repo にコミットしないこと。
2. 再デプロイすると `dashboard/admin.template.html` から `${ADMIN_FILENAME}.html` が生成されます (build.sh が起動時に検証、両方揃っていないと失敗)。
3. Cloudflare Dashboard → Zero Trust → Access → Applications → Add an application → Self-hosted:
   - Application domain: Pages のドメイン
   - Path: `/${ADMIN_FILENAME}.html` (実値で記載)
   - Identity providers: One-time PIN (メール) または Google など
   - Policy: Include - Emails - 自分のメールアドレス
4. アクセス時は `https://<pages-domain>/${ADMIN_FILENAME}.html` を開く → Access 認証画面 → 通過 → 管理画面表示

ファイル名を変更したい場合は `ADMIN_FILENAME` を書き換えて再デプロイし、Access ポリシーの Path も更新します。古いファイル名はビルドで再生成されないため自動的に 404 になります。

## セッション自動 close (pg_cron)

Migration 005 が pg_cron ジョブを 5 分毎に走らせ、最後の `yakiimo_temp_logs` 投入から 30 分以上経過したセッションを `is_public = false` に落とします。ESP32 を切り忘れて公開し続ける事故の保険です。手動で公開し直すには管理画面から `is_public` を切替えます。

cron ジョブの状態確認:

```sql
select * from cron.job where jobname = 'yakiimo_close_idle_sessions';
select * from cron.job_run_details order by start_time desc limit 5;
```

## 動作確認の流れ

1. ESP32 Web UI で 5 つの温度値・湿度・気圧・WiFi RSSI・現在の SSID/IP・セッション ID・「DB保存」スイッチが表示されること。
2. `wrangler tail` (worker/) で Worker に POST が届き、201 を返していること。
3. Supabase Dashboard → Table Editor → `yakiimo_temp_logs` で 5 秒ごとに 5 行ずつ追加されていること (`scripts/check_data.sh` で最新 50 行確認可)。
4. `yakiimo_sessions` に当該 `session_id` 行が存在し、管理画面から `is_public=true` にすると公開ダッシュボードに 5 秒ごとに更新される折れ線グラフが描画されること。
5. ライターで熱電対の先端を炙ると、該当 ch の温度カードと折れ線が応答して上昇すること。

## トラブルシューティング

| 症状 | 確認 |
|------|------|
| `MAX31855 init failed` | CS ピンの配線間違い、3V3 欠落。クローン基板でプルアップ未実装が疑われる場合は CS×4 + SO 共通に 10kΩ プルアップ後付け |
| 温度値がガタガタ揺れる | 各 MAX31855 の T+/T- 間に 10nF が挿さっているか確認 |
| 1 ch だけ NaN | 熱電対の断線、または極性逆 (赤を T+ に) |
| ESP32 ログに `ingest POST failed status=401` | Worker と ESP32 で `INGEST_HMAC_SECRET` / `ingest_hmac_secret` が一致していない、もしくは ESP32 の時刻が NTP 同期前 (timestamp が範囲外) |
| ESP32 ログに `ingest POST failed status=415/400` | リクエスト形式不正。yakiimo.yaml を改造した場合のみ起こり得る (詳細は worker/README.md) |
| ESP32 ログに `ingest POST failed status=502` | Worker は受理したが Supabase へ転送失敗。Worker の secret (`SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY`) を確認 |
| ダッシュボードが空 | `is_public=true` のセッションが無い (管理画面で切替)、または Max Rows を 50000 に上げ忘れ |
| 公開セッションが勝手に消える | pg_cron の 30 分 idle 自動 close。意図的に止めたい場合は migration 005 の cron job を `cron.unschedule()` |
| WiFi に繋がらない | AP モード `Yakiimo Fallback` に降格しているはず。スマホで接続後 captive portal で再設定 |
| OTA に失敗する | `ping yakiimo-temp-monitor.local` で mDNS 解決確認。失敗するなら Web UI の「IP アドレス」を見て `--device <IP>` 指定 |

## 関連ドキュメント

- 配線図 (SVG): [`docs/wiring-diagram.svg`](docs/wiring-diagram.svg)
- ドメイン辞書 (CONTEXT): [`docs/CONTEXT.md`](docs/CONTEXT.md)
- Ingest Contract 仕様 (auto-generated): [`docs/CONTRACT.md`](docs/CONTRACT.md)
- 設計判断記録 (ADR): [`docs/adr/`](docs/adr/)
- Contract package 実体: [`contract/src/`](contract/src/)
- ダッシュボード詳細: [`dashboard/README.md`](dashboard/README.md)
- Worker 詳細: [`worker/README.md`](worker/README.md)
- DB マイグレーション: [`supabase/migrations/`](supabase/migrations/)

## ライセンス

MIT License. 本リポジトリのコードは MIT ライセンスで公開しています。LICENSE ファイルは別途追加予定です。
