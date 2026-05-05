# yakiimo-temp-monitor

ESP32 と熱電対 4 本 + 環境センサーで、やきいも(石焼き芋)下焼き工程の温度を 5 チャンネル同時計測し、Supabase に蓄積してブラウザでリアルタイム可視化するオープンハードウェア / オープンソースプロジェクトです。1 セッションあたり約 2 時間の焼成中、芋の内部温度・芋の表面温度・釜内雰囲気温度・石の表面温度・屋外環境(気温/湿度/気圧)を 5 秒間隔で記録します。

## 概要

- ハードウェア: ESP32-DevKitC-32E + MAX31855 × 4 (K 型熱電対 IC) + BME280 (温湿度気圧 I2C)
- ファームウェア: ESPHome ベース (`firmware-esphome/yakiimo.yaml`)
- データ層: Supabase PostgREST + Row Level Security
- ダッシュボード: Vanilla HTML + Chart.js + supabase-js (Cloudflare Pages にそのままデプロイ可)
- サンプリング: 全 5 チャンネル 5 秒統一、5 秒ごとに 5 行を 1 回のバッチ POST
- 計測時間: 1 セッション ≒ 2 時間、データ量 ≒ 14,400 行
- 操作: ESP32 の Web UI (mDNS `yakiimo-temp-monitor.local`) でセッション ID 変更・現在値確認、OTA で再書き込み

スクリーンショット (※ リポジトリには `*.png` を含めない方針です。試運転時に各自で取得してください)

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
                     | HTTPS POST (5 行 / 5 秒)
                     v
        +-------------------------------+
        | Supabase                      |
        | - yakiimo_temp_logs (RLS)     |
        | - anon: INSERT + SELECT       |
        +---------------+---------------+
                        |
                        | fetch (anon key, RLS で SELECT のみ可)
                        v
        +-------------------------------+
        | Dashboard (静的サイト)        |
        | Chart.js + supabase-js        |
        | Cloudflare Pages にデプロイ可 |
        +-------------------------------+

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
- Cloudflare アカウント (ダッシュボードを Cloudflare Pages に置く場合のみ。任意)

### ソフトウェア

- Python 3.9 以上 (ESPHome 実行用)
- ESPHome 2024.x 以降 (本リポジトリは 2026 系の `request_headers:` 新方式で書かれています)
- Node.js 18 以降 + `wrangler` (Cloudflare Pages にデプロイする場合のみ)

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
2. Dashboard 左サイドバーの **SQL Editor** を開き、以下 2 ファイルを順番に貼り付けて実行します。
   - [`supabase/migrations/001_create_yakiimo_temp_logs.sql`](supabase/migrations/001_create_yakiimo_temp_logs.sql) — テーブル `yakiimo_temp_logs` 作成 + インデックス + RLS 有効化 + `anon insert only` ポリシー
   - [`supabase/migrations/002_add_anon_select.sql`](supabase/migrations/002_add_anon_select.sql) — ダッシュボードからの読取りに必要な `anon select all` ポリシーを追加
3. **Project Settings → API** から以下 2 つを控えます。
   - `Project URL` (例: `https://xxxxx.supabase.co`) — `secrets.yaml` の `supabase_url` に設定
   - `anon` `public` key (200 文字超の JWT) — `secrets.yaml` の `supabase_anon_key` に設定
4. **Project Settings → API → Max Rows** を 1000 から 50000 に引き上げます。ダッシュボードはセッション全期間 (約 14,400 行) を一括取得して表示するため、デフォルトの 1000 行制限では切れます。
5. 認証関連 (Authentication) は変更不要です。データの読み書きはすべて anon key + RLS ポリシー経由です。

テーブル定義の要点 (詳細は SQL ファイル参照):

| カラム | 型 | 説明 |
|--------|-----|------|
| `id` | BIGSERIAL PK | 連番 |
| `measured_at` | TIMESTAMPTZ | 計測時刻 (UTC) |
| `device_id` | TEXT | デバイス ID (例: `esp32-01`) |
| `session_id` | TEXT | セッション識別子 (例: `2026-05-04-round1`) |
| `channel` | TEXT | `potato_internal` / `potato_surface` / `kiln_ambient` / `stone_surface` / `env` |
| `temp_c` | REAL | 温度 (°C)、欠測時 NULL |
| `humidity_pct` | REAL | 湿度 (%)、env 行のみ |
| `pressure_hpa` | REAL | 気圧 (hPa)、env 行のみ |
| `raw` | JSONB | 予備、現在は未使用 |
| `ingested_at` | TIMESTAMPTZ | DB 投入時刻 (DEFAULT now()) |

## ファームウェア

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
| `supabase_anon_key` | Supabase anon public key |
| `session_id` | 計測セッションのラベル初期値。後で Web UI から変更可で NVS に永続化される |
| `brand_name` | 屋号 / 店名。Web UI とダッシュボードのタイトルに表示される。空欄でも可 |

`secrets.yaml` は `.gitignore` で除外されるためコミットされません。

### 初回書き込み (USB)

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
- `[D][http_request:xxx]: ... Code: 201` — Supabase への INSERT 成功

ブラウザで以下にアクセスすると Web UI が開き、Basic 認証ののち全センサーの現在値・WiFi 接続情報・セッション ID が表示されます。

```
http://yakiimo-temp-monitor.local/
```

mDNS が解決できない環境では、シリアルログの `IP Address:` 行で IP を確認して直打ちしてください。

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

## ダッシュボード

### ローカル確認

```bash
cd dashboard
cp main.js.example main.js
```

`main.js` 冒頭の以下 3 定数を実値に書き換えます (`secrets.yaml` と同じ値で OK)。

```javascript
const SUPABASE_URL = "https://YOUR_PROJECT.supabase.co";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
const BRAND_NAME = "[屋号]";
```

その上で簡易 HTTP サーバを立てます (`file://` 直開きでも動きますが、将来追加機能で fetch を使う場合に備えて HTTP サーバ起動を推奨)。

```bash
python3 -m http.server 8000
# ブラウザで http://localhost:8000/ を開く
```

### Cloudflare Pages デプロイ (任意)

任意ですが、本リポジトリには `secrets.yaml` から `main.js` への値同期 + `wrangler` でのデプロイを一括実行するスクリプトを同梱しています。

```bash
bash scripts/deploy-dashboard.sh
```

手動でデプロイする場合は:

```bash
npm install -g wrangler
wrangler login
wrangler pages deploy dashboard --project-name yakiimo-temp-monitor
```

詳細は [`dashboard/README.md`](dashboard/README.md) を参照してください。

## 動作確認の流れ

1. ESP32 Web UI で 5 つの温度値・湿度・気圧・WiFi RSSI・現在の SSID/IP・セッション ID が表示されること。
2. Supabase Dashboard → Table Editor → `yakiimo_temp_logs` で 5 秒ごとに 5 行ずつ追加されていること。`scripts/check_data.sh` を実行すると最新 50 行が確認できます。
3. ダッシュボード (ローカル http://localhost:8000/ または Cloudflare Pages) で 5 チャンネルの折れ線グラフが描画され、5 秒ごとに更新されること。
4. ライターで熱電対の先端を炙ると、該当 ch の温度カードと折れ線が応答して上昇すること。

## トラブルシューティング

| 症状 | 確認 |
|------|------|
| `MAX31855 init failed` | CS ピンの配線間違い、3V3 欠落。クローン基板でプルアップ未実装が疑われる場合は CS×4 + SO 共通に 10kΩ プルアップ後付け |
| 温度値がガタガタ揺れる | 各 MAX31855 の T+/T- 間に 10nF が挿さっているか確認 |
| 1 ch だけ NaN | 熱電対の断線、または極性逆 (赤を T+ に) |
| Supabase POST が `Code: 401` | `secrets.yaml` の `supabase_anon_key` がプレースホルダのまま。200 字超の本物の JWT に書き換える |
| Supabase POST が `Code: 403` | RLS の `anon insert only` ポリシーが投入されていない。`001_create_yakiimo_temp_logs.sql` を再実行 |
| ダッシュボードが空 | `002_add_anon_select.sql` を実行したか、Max Rows を 50000 に上げたか確認 |
| WiFi に繋がらない | AP モード `Yakiimo Fallback` に降格しているはず。スマホで接続後 captive portal で再設定 |
| OTA に失敗する | `ping yakiimo-temp-monitor.local` で mDNS 解決確認。失敗するなら Web UI の「IP アドレス」を見て `--device <IP>` 指定 |

## 関連ドキュメント

- 配線図 (SVG): [`docs/wiring-diagram.svg`](docs/wiring-diagram.svg)
- ダッシュボード詳細: [`dashboard/README.md`](dashboard/README.md)

## ライセンス

MIT License. 本リポジトリのコードは MIT ライセンスで公開しています。LICENSE ファイルは別途追加予定です。
