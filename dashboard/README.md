# dashboard — Yakiimo Temp Monitor

ESP32 が Supabase へ送信した 5 チャンネル温度ログをブラウザで可視化する静的ダッシュボード。
**Cloudflare Pages にそのままデプロイできる Vanilla HTML/CSS/JS** で実装してある(ビルド不要)。

## ファイル構成

```
dashboard/
├── index.html   メイン HTML(構造とライブラリ読込のみ)
├── style.css    ダーク + 暖色アクセントのスタイル
├── main.js      Supabase クエリ・Chart.js 描画・自動更新ロジック
└── README.md    本ファイル
```

## 機能

- 5 チャンネル(potato_internal / potato_surface / kiln_ambient / stone_surface / env)の時系列折れ線グラフ
- 各チャネルの現在値カード(°C、大きく表示、色分け)
- 環境センサーの湿度(%)・気圧(hPa)パネル
- 過去24時間に存在した `session_id` のドロップダウン(デフォルト最新)
- 5 秒間隔の増分取得 + ライブ表示(直近 30 分窓)
- 「更新: HH:MM:SS」表示と pulsing dot による生存感
- セッション開始からの経過時間カウンタ
- iPhone / iPad / PC レスポンシブ
- ダークモード固定(屋外でも視認しやすい)

## 初期セットアップ

`main.js` は anon key の実値を含むため `.gitignore` で除外している。
クローン直後は `main.js.example` をコピーして実値を埋める:

```bash
cd /Users/panp/src/company/projects/yakiimo-temp-monitor/dashboard
cp main.js.example main.js
# main.js を編集し SUPABASE_ANON_KEY を実値に書き換える
# (実値は firmware-esphome/secrets.yaml の supabase_anon_key と同じ)
```

## ローカルで開く方法

### A. `python3 -m http.server` (推奨)

```bash
cd /Users/panp/src/company/projects/yakiimo-temp-monitor/dashboard
python3 -m http.server 8000
```

ブラウザで <http://localhost:8000/> を開く。

### B. `file://` で直接開く

`index.html` をダブルクリックして開ける(CDN は HTTPS だが、現代ブラウザは
`file://` 直開きでも CORS が通る)。ただし将来、`fetch` を使う追加機能を加えた場合は
ローカルサーバ起動が必要になることがある。

> Anon key 未設定のままでも画面は表示され、上部に警告バナーで設定方法を案内する。
> グラフは空のまま、Supabase クエリは発行しない。

## 設定 — Supabase URL と anon key

`main.js` の冒頭にある以下 2 定数を実値に書き換える:

```javascript
const SUPABASE_URL = "https://YOUR_PROJECT.supabase.co";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";   // ← ここを書き換える
```

anon key は `firmware-esphome/secrets.yaml` の `supabase_anon_key` と同じ値を使う。

> **anon key を HTML/JS に直書きすることのセキュリティ判断**
>
> Supabase の anon key は元から公開を想定された JWT。
> `yakiimo_temp_logs` テーブルは `supabase/migrations/002_add_anon_select.sql` で
> RLS により anon に対し SELECT のみ許可、UPDATE/DELETE は不可。
> 焼き芋の温度データは非機密のため、URL を知る者は誰でも閲覧可で問題ない設計。
> 公開を望まないデータが将来含まれる場合は、別テーブルへ分離するか auth ロール導入を検討。

## Cloudflare Pages デプロイ手順

### 推奨: 一発デプロイスクリプト

`scripts/deploy-dashboard.sh` を実行すると、`firmware-esphome/secrets.yaml` から
`brand_name`, `supabase_url`, `supabase_anon_key` を読んで `dashboard/main.js` に
同期した上で `wrangler pages deploy` まで実行する。

```bash
cd /Users/panp/src/company/projects/yakiimo-temp-monitor
bash scripts/deploy-dashboard.sh
```

これにより `secrets.yaml` だけが正本となり、`dashboard/main.js` を手動で
編集する必要がなくなる。

### 方法 A: `wrangler` CLI(早い)

```bash
npm install -g wrangler
wrangler login
cd /Users/panp/src/company/projects/yakiimo-temp-monitor
wrangler pages deploy dashboard --project-name yakiimo-temp-monitor
```

初回はプロジェクト名を聞かれる。デプロイ後 `https://yakiimo-temp-monitor.pages.dev/` のような URL が発行される。

### 方法 B: ダッシュボードからの Direct Upload(GUI 派向け)

1. Cloudflare ダッシュボード → **Workers & Pages** → **Create application** → **Pages** → **Upload assets**
2. プロジェクト名を入力(例: `yakiimo-temp-monitor`)
3. `dashboard/` フォルダ内の 3 ファイル(index.html / style.css / main.js)を ZIP にしてアップロード、
   またはフォルダごとドラッグ
4. Deploy site

### 方法 C: Git 連携(継続運用には推奨)

1. Cloudflare ダッシュボード → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**
2. このリポジトリを選択
3. Build settings:
   - Build command: (空欄)
   - Build output directory: `dashboard`
4. main にマージするたびに自動デプロイされる

## CORS の注意

Supabase は anon ロールに対して全 origin から SELECT を許可するデフォルト設定なので追加設定は不要。
将来 origin 制限を行う場合は、Supabase の Project Settings → API → "URL Configuration" で
Cloudflare Pages の URL(`https://yakiimo-temp-monitor.pages.dev`)を allow list に追加する。

## トラブルシューティング

| 症状 | 確認ポイント |
|------|------|
| 上部に「anon key が未設定です」警告 | `main.js` の `SUPABASE_ANON_KEY` を実値に書き換える |
| 「過去24時間にデータなし」警告 | ESP32 が稼働中か、`yakiimo_temp_logs` に行が入っているか SQL Editor で確認 |
| グラフが更新されない | ブラウザコンソール(DevTools)で Supabase エラーメッセージを確認。401 なら anon key 不正、403 なら RLS の SELECT ポリシーが未投入(`002_add_anon_select.sql` 参照) |
| 線が一部のチャネルだけ出る | 該当 ch のセンサー断線または ESP32 ログを確認(`docs/wiring-table.md`) |
| ライブインジケータが赤く点滅 | 直近 30 秒以内にデータが届いていない。WiFi 切断・ESP32 停止を疑う |

## デザインメモ

- 配色: 焼き芋の世界観 — 橙(芋中身) / 黄(芋表面) / 赤(釜) / 灰(石) / 青(屋外)
- フォント: 大きめ。FB Live で画面共有しても識別できる視認性
- 過剰な装飾はせず、計測装置としての佇まいを優先
- 絵文字は brand mark として `🍠` のみ控えめに使用

## 関連

- ESP32 ファームウェア: `../firmware-esphome/yakiimo.yaml`
- Supabase テーブル定義: `../supabase/migrations/001_create_yakiimo_temp_logs.sql`
- anon SELECT ポリシー: `../supabase/migrations/002_add_anon_select.sql`
- 設計の経緯: `../README.md` の "後でやること(Phase 2 以降)" セクション
