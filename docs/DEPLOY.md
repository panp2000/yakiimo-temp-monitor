# Deploy environment — yakiimo-temp-monitor

本リポは Cloudflare Workers Build platform 上で **2 つの独立した Worker** として運用されている。リファクタリング・修正時は必ず本文書で現在地を確認すること。

## Worker の責務分担

| Worker name | 役割 | 関連ディレクトリ | wrangler config |
|---|---|---|---|
| `yakiimo-temp-monitor` | Live ダッシュボード + 管理画面の静的配信 (Workers Static Assets) | `dashboard/` | リポ root の `wrangler.toml` |
| `yakiimo-ingest` | ESP32 → Supabase の HMAC 認証付き ingest プロキシ | `worker/` | `worker/wrangler.toml` |

両者は名前空間を分けて独立 deploy される。互いに依存しない。

## yakiimo-temp-monitor (dashboard Worker)

### 配信構造

`dashboard/` ディレクトリを Workers Static Assets として配信する。Worker code (`main` field) は持たず、`[assets]` のみで成立する純粋な静的配信。

production URL: `https://yakiimo-temp-monitor.sai-kachi.workers.dev`

(独自ドメインを別途設定している場合は CF dashboard 側の Custom Domains で管理。本文書には記載しない)

### Build pipeline

CF Workers Build が以下の順で実行する:

1. **clone**: GitHub から main branch を pull
2. **dependency cache restore** + `npm clean-install`: root の package.json があるため CF が Node project と認識して走る (約 12s、279 packages)
3. **Build command** (CF dashboard で設定): `cd dashboard && bash build.sh`
   - `dashboard-shared` workspace を `npm --workspace=@yakiimo/dashboard-shared run build` で esbuild、`dashboard-shared/dist/dashboard-shared.js` を生成
   - `dashboard-shared.js` を `dashboard/` 配下に cp
   - `main.js.example` から env 値を埋めた `main.js` を生成
   - `ADMIN_FILENAME` env が設定されていれば `admin.template.html` から `${ADMIN_FILENAME}.html` を生成
4. **Deploy command** (CF dashboard で設定): `npx wrangler deploy`
   - root `wrangler.toml` を読み、`name = yakiimo-temp-monitor`、`[assets] directory = "./dashboard"` で deploy
   - `dashboard/.assetsignore` を見て除外対象 (build.sh / main.js.example 等) を hide
5. **build output cache**: 「not supported for your project」と CF が返すため、build output の cache は効かない。dependency cache のみ効く

### Deploy の前提条件 (必須)

deploy が成功するには以下が **同時に** 揃っている必要がある (どれか欠けるとビルドが落ちる):

- root `wrangler.toml` に project name + assets directory が明記されている
- root `package.json` の `devDependencies` に `wrangler` が入っており、`npm clean-install` で `node_modules/.bin/wrangler` が立つ
- CF dashboard の Deploy command が `npx wrangler deploy` (もしくは `npx wrangler versions upload`)
- CF dashboard の Build command が `cd dashboard && bash build.sh`
- CF dashboard の Environment variables (Production scope): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `BRAND_NAME`, (`ADMIN_FILENAME`, `SUPABASE_SERVICE_ROLE_KEY` は admin 画面を出すなら必須、任意で `SOCIAL_TWITTER` 等)

### 「リポに wrangler.toml が無くても動いた」時代の終焉 (172478a 事故記録)

**2026-05-07 の事故と再発防止のための記録**:

- 元々この project は CF Pages として運用されていたが、ある時点で Workers Build に migration された (リポからは時期確定不能、CF dashboard 側の操作)
- migration 後、リポに root package.json が **無い間** は CF が「静的サイト project」と認識し、`npm install` も deploy command も走らせず、build script の出力 dir をそのまま静的公開していた。CF Workers Auto-Config が背後で assets directory を wrangler に渡していたとも推察される
- 2026-05-07 commit `172478a` (Yakiimo Ingest Contract 用の root package.json + workspaces 初導入) で CF が Node project 認識に切り替わり、`npm clean-install` が走るようになった
- 同時に Deploy command の挙動が変化:
  - 過去成功時 (root package.json なし): `npx wrangler versions upload` → npx auto-install で wrangler 4.88.0 を fetch → 成功
  - 172478a 後: `npx wrangler deploy` (CF が変更したか user が変更したか不明) → `npm clean-install` 後の npx は auto-install が抑止される模様 → `sh: 1: wrangler: not found`
  - `npx -y wrangler@4 versions upload` で auto-install を強制すると wrangler は起動するが、CF auto-config が assets directory を渡せておらず「Missing entry-point to Worker script or to assets directory」で失敗
- **解決**: commit `10e3667` (Stage 12-A) で root に `wrangler.toml` 新設 + `wrangler ^4.0.0` を root devDependencies に追加。これにより:
  - `npm clean-install` で local の `wrangler` binary が確実に立つ
  - wrangler が assets directory / project name を repo の wrangler.toml から読む (CF auto-config に依存しない)
  - deploy command が `npx wrangler deploy` でも `npx wrangler versions upload` でも安定動作

### 今後の運用ルール

1. **CF dashboard の Build/Deploy command は変更しない** (動いている設定を保つ)。変更する必要が出たら本文書を必ず更新する
2. **root の wrangler.toml と wrangler devDep は意図的に repo 側にある**。「CF 側で auto-config してくれるから不要では」と削除しないこと。172478a 以降の事故再発を防ぐため
3. **`dashboard/` 配下に新規ファイルを置くときは公開可否を判断する**。公開不要なら `dashboard/.assetsignore` に追加する。現在の除外: `build.sh`, `main.js.example`, `*.example`, `admin.template.html`

## yakiimo-ingest (ESP32 ingest Worker)

`worker/` 配下、`worker/wrangler.toml` で独立管理。詳細は `worker/README.md` を参照。

deploy: `cd worker && npx wrangler deploy` (CF dashboard 経由ではなく、ローカルから手動 deploy するパターン)

secrets (`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `INGEST_HMAC_SECRET`) は `npx wrangler secret put` で個別投入。詳細は `worker/README.md` 参照。

## 関連ドキュメント

- ドメイン用語: `docs/CONTEXT.md`
- Ingest Contract 仕様: `docs/CONTRACT.md` (auto-generated)
- ADR: `docs/adr/`
- Worker (ingest) 詳細: `worker/README.md`
- Dashboard 詳細: `dashboard/README.md`
