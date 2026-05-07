# Database Schema — yakiimo-temp-monitor

本文書は Supabase (PostgreSQL) に存在するスキーマ・テーブル・トリガー・cron ジョブ・RLS ポリシーを **観測される migration を出典として** まとめる。migration の番号順に変更履歴を辿るための一覧表もここに置く。設計思想は `docs/CONTEXT.md`、ingest contract の値域は `docs/CONTRACT.md`、上位の防御層は `docs/THREAT-MODEL.md` を参照。

参照する migration は `supabase/migrations/` 配下の以下 9 ファイル:

- `001_create_yakiimo_temp_logs.sql`
- `002_add_anon_select.sql`
- `003_harden_rls.sql`
- `004_create_yakiimo_sessions.sql`
- `005_setup_auto_close_cron.sql`
- `006_drop_anon_insert.sql`
- `007_contract_functions.sql`
- `008_use_contract_functions.sql`
- `009_add_unique_constraint.sql`

## 概要

- スキーマ
  - `public` — 業務テーブル本体 (`yakiimo_temp_logs`, `yakiimo_sessions`)
  - `internal` — `SECURITY DEFINER` 関数 / contract validator / pg_cron 用関数を隔離 (migration 004:41 で `CREATE SCHEMA IF NOT EXISTS internal` 導入、migration 007:12 で再宣言)
  - `cron` — pg_cron 拡張が提供 (`cron.job`, `cron.job_run_details`, `cron.schedule()`, `cron.unschedule()`)
- 拡張: `pg_cron` (migration 005:26 で `CREATE EXTENSION IF NOT EXISTS pg_cron`)
- 主要テーブル: `yakiimo_temp_logs` (5ch 時系列計測値、migration 001), `yakiimo_sessions` (セッションメタ + `is_public` 排他制御、migration 004)
- RLS: 両テーブルで有効化済 (migration 001:31, 004:62)。anon は SELECT のみ (公開条件付き)。service_role は RLS bypass するが、`yakiimo_temp_logs` には migration 008 で BEFORE INSERT trigger による contract 検証が張られ、bypass 不能の最終ゲートとして機能する。
- Defense in Depth との対応: Worker (L1+L2) は contract module を import (`worker/src/index.ts:1-6, 47-90`)、Supabase (L3) は internal schema 配下の validator + BEFORE INSERT trigger (migration 007/008)。詳細は `docs/THREAT-MODEL.md`。

## yakiimo_temp_logs

ESP32 から流入する温度時系列の生データを保持する append-only テーブル。

### Definition (migration 001:5-16)

| 列 | 型 | NULL | デフォルト | 値域 / 備考 | 出典 |
|---|---|---|---|---|---|
| `id` | `BIGSERIAL` | NOT NULL | sequence | PRIMARY KEY | migration 001:6 |
| `measured_at` | `TIMESTAMPTZ` | NOT NULL | — | 測定時刻 (ESP32 側採番)。許容窓は `now() - 1 day < t < now() + 1 hour` (`internal.yakiimo_valid_measured_at`、migration 007:35-41) | migration 001:7, 007:35-41 |
| `device_id` | `TEXT` | NOT NULL | `'esp32-01'` | 形式: `^[a-z0-9_-]{1,32}$` | migration 001:8, 007:21-26 |
| `session_id` | `TEXT` | NOT NULL | — | 形式: `^[a-zA-Z0-9_-]{1,64}$` | migration 001:9, 007:28-33 |
| `channel` | `TEXT` | NOT NULL | — | 5 値ドメイン: `potato_internal` / `potato_surface` / `kiln_ambient` / `stone_surface` / `env` | migration 001:10, 007:14-19 |
| `temp_c` | `REAL` | NULL 許容 | — | NULL or `-50 <= v <= 1500` | migration 001:11, 007:43-48 |
| `humidity_pct` | `REAL` | NULL 許容 | — | NULL or `0 <= v <= 100` | migration 001:12, 007:50-55 |
| `pressure_hpa` | `REAL` | NULL 許容 | — | NULL or `800 <= v <= 1200` | migration 001:13, 007:57-62 |
| `raw` | `JSONB` | NULL 許容 | — | センサ生データの保管枠 (現状 Worker は未使用) | migration 001:14 |
| `ingested_at` | `TIMESTAMPTZ` | NOT NULL | `now()` | 行が DB に到達した時刻 | migration 001:15 |

値域の単一出典は `contract/src/payload.ts:3-23`。SQL 検証関数 (`internal.yakiimo_valid_*`) は migration 007 でこの TS 定義から `npm run codegen` により自動生成される (migration 007:1-9 のヘッダコメント、`README.md:217-221`)。

`channel` には CHECK 制約は付いていない (migration 001:18-23 に「documented; not enforced as CHECK to keep flexibility」と明記)。channel 値の強制は migration 008 の BEFORE INSERT trigger 経由で行う。

INSERT 経路は Worker (`worker/src/index.ts:93-102`、`service_role` で REST `/rest/v1/yakiimo_temp_logs` に PostgREST POST) のみ。anon INSERT は migration 006 で撤去済 (後述)。

### Indexes (migration 001:25-29)

| index 名 | 列 | 用途 |
|---|---|---|
| `yakiimo_temp_logs_session_measured_idx` | `(session_id, measured_at)` | セッション別の時系列取得 |
| `yakiimo_temp_logs_channel_measured_idx` | `(channel, measured_at DESC)` | チャンネル別の最新データ取得 |

### 制約 (migration 009)

- `yakiimo_temp_logs_unique_measurement` UNIQUE (`device_id`, `session_id`, `channel`, `measured_at`) (`supabase/migrations/009_add_unique_constraint.sql:13-15`) — 同一 measurement の重複 INSERT を阻止、replay 攻撃 / 通信再送による重複行を排除

### RLS policies (最終状態)

`ENABLE ROW LEVEL SECURITY` は migration 001:31 で実施。

| polname | 種別 | role | cmd | 条件 | 出典 |
|---|---|---|---|---|---|
| `anon select live public only` | PERMISSIVE | anon | SELECT | `session_id IN (SELECT session_id FROM public.yakiimo_sessions WHERE is_public = true)` | migration 004:174-182 |
| `anon no update` | RESTRICTIVE | anon | UPDATE | `USING (false)` | migration 003:58-64 |
| `anon no delete` | RESTRICTIVE | anon | DELETE | `USING (false)` | migration 003:66-72 |

撤去済 / 置換済の policy:

- `anon insert only` (PERMISSIVE, anon, INSERT)
  - migration 001:35-40 で WITH CHECK (true) で初出
  - migration 003:34-48 で WITH CHECK 値検証付きに強化 (DROP & CREATE)
  - **migration 006:24 で DROP**。以降 anon は INSERT 不可。
- `anon select all` (PERMISSIVE, anon, SELECT, USING (true))
  - migration 002:23-28 で追加
  - **migration 004:172 で DROP** され `anon select live public only` に置換

`service_role` は明示 policy を持たず、PostgreSQL の RLS bypass attribute によりすべての操作が通る (Supabase の標準動作)。INSERT 時の検証は次節の BEFORE INSERT trigger が `service_role` 含む全ロールに対して実行される。

### BEFORE INSERT trigger (migration 008)

```
yakiimo_temp_logs_validate_trigger
  BEFORE INSERT ON public.yakiimo_temp_logs
  FOR EACH ROW EXECUTE FUNCTION internal.yakiimo_temp_logs_validate()
```

- 出典: migration 008:69-73
- trigger 関数 `internal.yakiimo_temp_logs_validate()` は `SECURITY DEFINER`、`SET search_path = public, internal, pg_temp` (migration 008:24-29)
- 7 つの contract validator (`internal.yakiimo_valid_channel` / `_device_id` / `_session_id` / `_measured_at` / `_temp` / `_humidity` / `_pressure`) を順次呼び、違反があれば `ERRCODE = '23514'` で `RAISE EXCEPTION` (migration 008:31-58)
- `BEFORE INSERT` のみで `UPDATE` は対象外 (migration 008:66-67 のコメント: 「admin の事後修正で古い measured_at が validation に引っかかるのを避ける」)
- RLS は role 経由で bypass されるが、trigger は bypass されない。Worker bug や admin 直接 INSERT (`service_role`) でも contract 違反は弾かれる (Defense in Depth Layer 3、migration 008:8-12)

### AFTER INSERT trigger (migration 004)

```
yakiimo_temp_logs_ensure_session
  AFTER INSERT ON public.yakiimo_temp_logs
  FOR EACH ROW EXECUTE FUNCTION internal.ensure_session_record()
```

- 出典: migration 004:94-96
- 関数 `internal.ensure_session_record()` (migration 004:78-92) は `SECURITY DEFINER`。`yakiimo_sessions` への UPSERT を行う:
  - 新 `session_id` であれば `INSERT (session_id, started_at, ended_at) VALUES (NEW.session_id, NEW.measured_at, NEW.measured_at)` (`is_public` は DEFAULT false で起票)
  - 既存 `session_id` であれば `ON CONFLICT (session_id) DO UPDATE SET ended_at = NEW.measured_at, updated_at = now()`
- 結果として `yakiimo_sessions.ended_at` は常に「そのセッションの最終 INSERT 時刻」を保持する (pg_cron による idle 検知の根拠)。

## yakiimo_sessions

セッション単位のメタデータ + 公開制御 (`is_public`) を保持。

### Definition (migration 004:47-60)

| 列 | 型 | NULL | デフォルト | 制約 / 備考 | 出典 |
|---|---|---|---|---|---|
| `session_id` | `TEXT` | NOT NULL | — | PRIMARY KEY (`yakiimo_temp_logs.session_id` と同一書式) | migration 004:48 |
| `display_name` | `TEXT` | NULL 許容 | — | 表示用ラベル | migration 004:49 |
| `purpose` | `TEXT` | NOT NULL | `'cook'` | `CHECK (purpose IN ('cook','cool','test','other'))` | migration 004:50-51 |
| `is_public` | `BOOLEAN` | NOT NULL | `false` | live 公開制御。同時 true は最大 1 行 (排他保証) | migration 004:52 |
| `started_at` | `TIMESTAMPTZ` | NULL 許容 | — | 最初の INSERT 時刻 (trigger でセット) | migration 004:53 |
| `ended_at` | `TIMESTAMPTZ` | NULL 許容 | — | 最後の INSERT 時刻 (trigger で随時更新) | migration 004:54 |
| `fire_start_at` | `TIMESTAMPTZ` | NULL 許容 | — | 着火時刻 (オーナー手入力枠) | migration 004:55 |
| `notes` | `TEXT` | NULL 許容 | — | フリーテキスト | migration 004:56 |
| `brix` | `REAL` | NULL 許容 | — | 完成芋の Brix 値 | migration 004:57 |
| `created_at` | `TIMESTAMPTZ` | NOT NULL | `now()` | — | migration 004:58 |
| `updated_at` | `TIMESTAMPTZ` | NOT NULL | `now()` | trigger で auto-touch | migration 004:59 |

`ENABLE ROW LEVEL SECURITY` は migration 004:62 で実施。

### Indexes (migration 004)

| index 名 | 定義 | 用途 |
|---|---|---|
| (PK) | `PRIMARY KEY (session_id)` | テーブル定義 |
| `yakiimo_sessions_single_public_idx` | `UNIQUE ((1)) WHERE is_public = true` (partial unique) | **同時 `is_public=true` を 1 行に強制**。migration 004:65-66 |

partial unique index による排他は SQL 制約レベルでの最後の砦。これと並行して BEFORE トリガー (`enforce_single_public_session`、後述) が前段で他行を flip-down するため、二重防御になる (migration 004:101-103 のコメント: 「ベルト+サスペンダー」)。

### RLS policies (最終状態、migration 004:150-161)

| polname | 種別 | role | cmd | 条件 | 出典 |
|---|---|---|---|---|---|
| `anon select public sessions only` | PERMISSIVE | anon | SELECT | `is_public = true` | migration 004:150-154 |
| `anon no insert sessions` | RESTRICTIVE | anon | INSERT | `WITH CHECK (false)` | migration 004:156-157 |
| `anon no update sessions` | RESTRICTIVE | anon | UPDATE | `USING (false)` | migration 004:158-159 |
| `anon no delete sessions` | RESTRICTIVE | anon | DELETE | `USING (false)` | migration 004:160-161 |

anon の挙動: `is_public=true` の 1 行のみ可視。INSERT/UPDATE/DELETE は全て拒否。`service_role` は RLS bypass で全件参照・更新可 (オーナー専用管理画面はこちら)。

### Triggers

| trigger 名 | タイミング | 関数 | 役割 | 出典 |
|---|---|---|---|---|
| `yakiimo_sessions_single_public` | `BEFORE INSERT OR UPDATE OF is_public` | `internal.enforce_single_public_session()` | `is_public=true` への flip 時、他の `is_public=true` 行を全て false に | migration 004:120-122 |
| `yakiimo_sessions_updated_at` | `BEFORE UPDATE` | `internal.update_updated_at()` | `updated_at = now()` を強制セット | migration 004:140-142 |

`enforce_single_public_session` (migration 004:104-118) は `OLD IS NULL OR OLD.is_public IS DISTINCT FROM true` で flip 検出し、自セッション以外の public 行を false に落とす。partial unique index と協調する (片方では UPDATE 競合で失敗するケースも、トリガで先行 flip-down することで通せる)。

### Backfill (migration 004:185-205)

migration 004 適用時点で既存の `yakiimo_temp_logs.session_id` を全件 `yakiimo_sessions` に backfill (`MIN/MAX(measured_at)` を `started_at`/`ended_at` に投入)。さらに `ended_at DESC NULLS LAST LIMIT 1` の最新 1 件のみ `is_public = true` に flip し、デプロイ瞬断で live が消えないようにしている (migration 004:200-205)。これは 1 回限りの DML で、以降の運用には影響しない。

## internal schema

`SECURITY DEFINER` 関数を `public` から逃して anon/authenticated への暗黙 EXECUTE 露出を避ける目的で導入 (migration 004:37-41 のコメント参照)。

### Contract validator 関数 (migration 007、auto-generated)

`contract/src/payload.ts` から `npm run codegen` で再生成される。**手で migration 007 を編集してはいけない** (migration 007:1-9 のヘッダ、`README.md:215-221`)。

| 関数名 | 引数 | 返り値 | 言語 | volatility | 用途 |
|---|---|---|---|---|---|
| `internal.yakiimo_valid_channel(text)` | `c` | `boolean` | SQL | IMMUTABLE | `c IN ('potato_internal','potato_surface','kiln_ambient','stone_surface','env')` (migration 007:14-19) |
| `internal.yakiimo_valid_device_id(text)` | `d` | `boolean` | SQL | IMMUTABLE | `d ~ '^[a-z0-9_-]{1,32}$'` (migration 007:21-26) |
| `internal.yakiimo_valid_session_id(text)` | `s` | `boolean` | SQL | IMMUTABLE | `s ~ '^[a-zA-Z0-9_-]{1,64}$'` (migration 007:28-33) |
| `internal.yakiimo_valid_measured_at(timestamptz)` | `t` | `boolean` | SQL | STABLE | `t > now() - interval '1 day' AND t < now() + interval '1 hour'` (migration 007:35-41) |
| `internal.yakiimo_valid_temp(real)` | `v` | `boolean` | SQL | IMMUTABLE | `v IS NULL OR (v >= -50 AND v <= 1500)` (migration 007:43-48) |
| `internal.yakiimo_valid_humidity(real)` | `v` | `boolean` | SQL | IMMUTABLE | `v IS NULL OR (v >= 0 AND v <= 100)` (migration 007:50-55) |
| `internal.yakiimo_valid_pressure(real)` | `v` | `boolean` | SQL | IMMUTABLE | `v IS NULL OR (v >= 800 AND v <= 1200)` (migration 007:57-62) |

すべて `SET search_path = pg_catalog`、`CREATE OR REPLACE` で冪等。

### Trigger 用関数

| 関数名 | 言語 | security | 役割 | 出典 |
|---|---|---|---|---|
| `internal.yakiimo_temp_logs_validate()` | plpgsql | DEFINER | `BEFORE INSERT` で 7 つの validator を順次呼び、違反は `ERRCODE 23514` で `RAISE EXCEPTION` | migration 008:24-61 |
| `internal.ensure_session_record()` | plpgsql | DEFINER | `yakiimo_temp_logs` AFTER INSERT を契機に `yakiimo_sessions` を UPSERT (`ended_at` 更新含む) | migration 004:78-92 |
| `internal.enforce_single_public_session()` | plpgsql | DEFINER | `is_public=true` への flip 時、他の public 行を false に flip-down | migration 004:104-118 |
| `internal.update_updated_at()` | plpgsql | DEFINER | `BEFORE UPDATE` で `NEW.updated_at = now()` を強制 | migration 004:128-138 |

すべて `SECURITY DEFINER` + `SET search_path = public, pg_temp` (008 のみ `public, internal, pg_temp`) で固定し、search_path injection を防いでいる。

## pg_cron jobs

`pg_cron` 拡張は migration 005:26 で `CREATE EXTENSION IF NOT EXISTS pg_cron`。Supabase ダッシュボードでの手動有効化は不要 (`README.md:193`)。

| jobname | schedule | 実行内容 | 目的 | 出典 |
|---|---|---|---|---|
| `yakiimo_auto_close_idle_sessions` | `*/5 * * * *` | `UPDATE public.yakiimo_sessions SET is_public = false, updated_at = now() WHERE is_public = true AND ended_at < now() - interval '30 minutes';` | 焼成終了後の `is_public` 戻し忘れカバー (5 分毎走査、最終 INSERT から 30 分超 idle のセッションを非公開化) | migration 005:45-55 |

migration 005:33-38 で `cron.unschedule('yakiimo_auto_close_idle_sessions')` を `DO $$ BEGIN PERFORM ... EXCEPTION WHEN OTHERS THEN NULL; END $$` で先に呼んでおり、再適用時の衝突を回避する。

確認 SQL (migration 005:62-78 と一致):

```sql
SELECT jobid, jobname, schedule, command, active
  FROM cron.job
 WHERE jobname = 'yakiimo_auto_close_idle_sessions';

SELECT jobid, runid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'yakiimo_auto_close_idle_sessions')
 ORDER BY start_time DESC
 LIMIT 10;
```

`docs/THREAT-MODEL.md` の Layer 7 (運用層) で本ジョブが言及される。

## RLS ポリシー一覧 (最終状態の集約)

| テーブル | polname | 種別 | role | 操作 | 条件 | 出典 (最終状態) |
|---|---|---|---|---|---|---|
| `yakiimo_temp_logs` | `anon select live public only` | PERMISSIVE | anon | SELECT | `session_id IN (SELECT session_id FROM yakiimo_sessions WHERE is_public = true)` | migration 004:174-182 |
| `yakiimo_temp_logs` | `anon no update` | RESTRICTIVE | anon | UPDATE | `false` | migration 003:58-64 |
| `yakiimo_temp_logs` | `anon no delete` | RESTRICTIVE | anon | DELETE | `false` | migration 003:66-72 |
| `yakiimo_temp_logs` | (anon INSERT 用 policy なし) | — | anon | INSERT | 暗黙拒否 | migration 006:24 で DROP |
| `yakiimo_temp_logs` | (service_role 用 policy なし) | — | service_role | * | RLS bypass。BEFORE INSERT trigger で contract 検証 | migration 008:69-73 |
| `yakiimo_sessions` | `anon select public sessions only` | PERMISSIVE | anon | SELECT | `is_public = true` | migration 004:150-154 |
| `yakiimo_sessions` | `anon no insert sessions` | RESTRICTIVE | anon | INSERT | `false` | migration 004:156-157 |
| `yakiimo_sessions` | `anon no update sessions` | RESTRICTIVE | anon | UPDATE | `false` | migration 004:158-159 |
| `yakiimo_sessions` | `anon no delete sessions` | RESTRICTIVE | anon | DELETE | `false` | migration 004:160-161 |
| `yakiimo_sessions` | (service_role 用 policy なし) | — | service_role | * | RLS bypass | — |

確認 SQL (migration 003:79-83 と migration 004:221-227):

```sql
SELECT polname, polcmd, polpermissive, polroles::regrole[]
  FROM pg_policy
 WHERE polrelid IN (
   'public.yakiimo_sessions'::regclass,
   'public.yakiimo_temp_logs'::regclass
 )
 ORDER BY polrelid::text, polname;
```

## Migration 履歴 (順序遵守)

| # | ファイル | 主な変更 | 注意点 |
|---|---|---|---|
| 001 | `001_create_yakiimo_temp_logs.sql` | `yakiimo_temp_logs` 作成、2 index、RLS 有効化、`anon insert only` (WITH CHECK true) | `channel` は CHECK 制約ではなくコメントで記載 (migration 001:18-23) |
| 002 | `002_add_anon_select.sql` | `anon select all` (USING true) を追加 | migration 004 で DROP され置換される過渡的 policy |
| 003 | `003_harden_rls.sql` | `anon insert only` を WITH CHECK 値検証付きに強化、`anon no update` / `anon no delete` (RESTRICTIVE) を追加 | UPDATE/DELETE は以降 RESTRICTIVE で必ず拒否 (migration 003:50-72) |
| 004 | `004_create_yakiimo_sessions.sql` | `internal` schema 作成、`yakiimo_sessions` 作成 + partial unique index、3 つの trigger 関数、`yakiimo_temp_logs` の SELECT を public セッション限定に置換、既存 session を backfill して最新 1 件を public 化 | `anon select all` (002) はここで DROP (migration 004:172) |
| 005 | `005_setup_auto_close_cron.sql` | `pg_cron` 拡張有効化、`yakiimo_auto_close_idle_sessions` cron job (5 分毎、30 分 idle で `is_public=false`) | 同名 job の事前 unschedule あり (migration 005:33-38) |
| 006 | `006_drop_anon_insert.sql` | `anon insert only` policy を DROP (Phase 8-C、Worker 経由化完了) | 以降 anon は INSERT 経路を持たない (migration 006:24) |
| 007 | `007_contract_functions.sql` | `internal.yakiimo_valid_*` 7 関数を登録 | **auto-generated、手編集禁止**。再生成は `npm run codegen` (migration 007:1-9) |
| 008 | `008_use_contract_functions.sql` | `yakiimo_temp_logs` に BEFORE INSERT trigger (`yakiimo_temp_logs_validate_trigger`) を張り、L3 検証を全ロールに強制 | `service_role` の RLS bypass を貫通する Defense in Depth Layer 3 (migration 008:8-12) |
| 009 | add_unique_constraint | yakiimo_temp_logs に (device_id, session_id, channel, measured_at) UNIQUE 制約。Worker の `Prefer: resolution=ignore-duplicates` と併用して replay dedup (THREAT-MODEL gap 4 対応) |  |

## RLS / trigger 進化の要点 (migration 跨り)

- `yakiimo_temp_logs` の anon INSERT 制御:
  - 001 (無検証 WITH CHECK true) → 003 (値検証 WITH CHECK) → 006 (撤去)。最終的に anon は INSERT 不可。
- `yakiimo_temp_logs` の anon SELECT 制御:
  - 002 (全件 USING true) → 004 (`is_public=true` セッションの logs のみ)。最終的に live 1 件のみ可視。
- `yakiimo_temp_logs` の INSERT 検証:
  - 001/003 は WITH CHECK で anon にのみ適用 → 006 で WITH CHECK 自体が消滅 → 008 で BEFORE INSERT trigger による全ロール検証へ移行。`service_role` を経由する Worker INSERT もここで再検証される。
- `internal` schema:
  - 004 で導入 → 007 で contract validator が追加 → 008 で trigger 関数が追加。`SECURITY DEFINER` を public 露出から逃す目的が一貫。

## 関連ドキュメント

- ドメイン用語: `docs/CONTEXT.md`
- Ingest Contract 仕様 (auto-gen): `docs/CONTRACT.md`
- 脅威モデル / Defense in Depth 全体像: `docs/THREAT-MODEL.md`
- Deploy 環境 / Worker / pg_cron: `docs/DEPLOY.md`
- セットアップ手順: `README.md` の「Supabase セットアップ」節 (本文書は SQL レベルの正規化された参照、README は手順ガイド)
