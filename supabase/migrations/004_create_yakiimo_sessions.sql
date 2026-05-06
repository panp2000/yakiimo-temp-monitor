-- 004_create_yakiimo_sessions.sql
-- yakiimo_sessions テーブル + 公開制御 RLS (Phase 1)
-- Project: Supabase project (https://YOUR_PROJECT.supabase.co)
-- Run via: Supabase Dashboard → SQL Editor (全文貼付け実行)
--
-- (前提)
--   001 で yakiimo_temp_logs を作成、anon INSERT 無条件。
--   002 で anon SELECT (USING (true)) を追加 (全行公開)。
--   003 で INSERT 値検証 + UPDATE/DELETE RESTRICTIVE deny。
--
-- (戦略文脈)
--   yakiimo-temp-monitor は live のみ一般公開、過去セッションは管理画面
--   (オーナー専用) でのみ閲覧、訪問者は SNS / ブログへ誘導する戦略。
--   本 phase ではその基盤として sessions テーブルを作成し、anon SELECT を
--   「is_public=true なセッションの logs のみ」に絞る。
--
-- (目的)
--   1. yakiimo_sessions テーブル新設 (display_name / purpose / is_public /
--      started_at / ended_at / fire_start_at / notes / brix)
--   2. 排他保証 (同時 is_public=true は 1 件のみ) を partial unique index +
--      BEFORE トリガーで二重に担保
--   3. yakiimo_temp_logs INSERT 時に sessions 行を自動作成 (is_public=false 初期値)
--   4. yakiimo_temp_logs の anon SELECT を「is_public=true セッションの logs のみ」
--      に絞り、URL クエリ経由での履歴 scraping 経路を遮断
--   5. SECURITY DEFINER 関数は internal schema へ隔離 (Supabase ベストプラクティス)
--   6. 既存 session_id を backfill、最新 1 件を is_public=true で起票
--
-- (適用順序) 001 → 002 → 003 → 004 の順で適用。本ファイルは 004。
-- (適用方法) Supabase Dashboard SQL Editor で本ファイル全文貼付け実行。
-- (ロールバック) 末尾コメントの ROLLBACK セクション参照 (実行不要・参考のみ)。

BEGIN;

-- ============================================================================
-- Section 1: schema 準備
-- ============================================================================
-- SECURITY DEFINER 関数を public 露出から逃すため internal schema を作成。
-- public schema 配下に SECURITY DEFINER 関数を置くと anon/authenticated に
-- EXECUTE 権限が付与されかねないため、Supabase ベストプラクティスに従い隔離する。

CREATE SCHEMA IF NOT EXISTS internal;

-- ============================================================================
-- Section 2: yakiimo_sessions テーブル
-- ============================================================================

CREATE TABLE public.yakiimo_sessions (
  session_id     TEXT PRIMARY KEY,
  display_name   TEXT,
  purpose        TEXT NOT NULL DEFAULT 'cook'
                 CHECK (purpose IN ('cook', 'cool', 'test', 'other')),
  is_public      BOOLEAN NOT NULL DEFAULT false,
  started_at     TIMESTAMPTZ,
  ended_at       TIMESTAMPTZ,
  fire_start_at  TIMESTAMPTZ,
  notes          TEXT,
  brix           REAL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.yakiimo_sessions ENABLE ROW LEVEL SECURITY;

-- 排他保証 (case A 採用): 同時 is_public=true は 1 件のみ
CREATE UNIQUE INDEX yakiimo_sessions_single_public_idx
  ON public.yakiimo_sessions ((1)) WHERE is_public = true;

COMMENT ON TABLE public.yakiimo_sessions IS
  'やきいも下焼きセッションのメタデータ。live 公開制御 (is_public) と purpose 別管理用。';

-- ============================================================================
-- Section 3: 自動セッション作成トリガー (yakiimo_temp_logs INSERT を契機)
-- ============================================================================
-- ESP32 が新 session_id でデータ送信開始した時、sessions に未登録なら
-- 自動作成 (is_public=false デフォルト)。既存なら ended_at を更新
-- (最終データ時刻を反映)。

CREATE OR REPLACE FUNCTION internal.ensure_session_record()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  INSERT INTO public.yakiimo_sessions (session_id, started_at, ended_at)
  VALUES (NEW.session_id, NEW.measured_at, NEW.measured_at)
  ON CONFLICT (session_id) DO UPDATE
    SET ended_at = NEW.measured_at,
        updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER yakiimo_temp_logs_ensure_session
  AFTER INSERT ON public.yakiimo_temp_logs
  FOR EACH ROW EXECUTE FUNCTION internal.ensure_session_record();

-- ============================================================================
-- Section 4: 排他公開強制トリガー
-- ============================================================================
-- is_public=true へ flip 時、他の is_public=true 行を全て false に。
-- partial unique index と二重に排他保証する (ベルト+サスペンダー)。

CREATE OR REPLACE FUNCTION internal.enforce_single_public_session()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NEW.is_public = true AND (OLD IS NULL OR OLD.is_public IS DISTINCT FROM true) THEN
    UPDATE public.yakiimo_sessions
       SET is_public = false, updated_at = now()
     WHERE is_public = true AND session_id != NEW.session_id;
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER yakiimo_sessions_single_public
  BEFORE INSERT OR UPDATE OF is_public ON public.yakiimo_sessions
  FOR EACH ROW EXECUTE FUNCTION internal.enforce_single_public_session();

-- ============================================================================
-- Section 5: updated_at 自動更新トリガー
-- ============================================================================

CREATE OR REPLACE FUNCTION internal.update_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER yakiimo_sessions_updated_at
  BEFORE UPDATE ON public.yakiimo_sessions
  FOR EACH ROW EXECUTE FUNCTION internal.update_updated_at();

-- ============================================================================
-- Section 6: yakiimo_sessions の RLS ポリシー
-- ============================================================================
-- anon は is_public=true 行のみ SELECT 可、他操作は全拒否。
-- INSERT/UPDATE/DELETE は service_role / Dashboard 経由でオーナーのみ可。

CREATE POLICY "anon select public sessions only"
  ON public.yakiimo_sessions
  FOR SELECT
  TO anon
  USING (is_public = true);

CREATE POLICY "anon no insert sessions" ON public.yakiimo_sessions
  AS RESTRICTIVE FOR INSERT TO anon WITH CHECK (false);
CREATE POLICY "anon no update sessions" ON public.yakiimo_sessions
  AS RESTRICTIVE FOR UPDATE TO anon USING (false);
CREATE POLICY "anon no delete sessions" ON public.yakiimo_sessions
  AS RESTRICTIVE FOR DELETE TO anon USING (false);

-- ============================================================================
-- Section 7: yakiimo_temp_logs RLS の SELECT 切替
-- ============================================================================
-- 旧「anon select all」(002 で追加) を削除し、is_public=true なセッションの
-- logs のみ SELECT 可へ。URL クエリ経由での履歴 scraping 経路を遮断する。
--
-- 注: subquery は anon 役で実行されるため yakiimo_sessions の anon SELECT
-- ポリシー (is_public=true のみ) も適用される。意味的には正しい。

DROP POLICY IF EXISTS "anon select all" ON public.yakiimo_temp_logs;

CREATE POLICY "anon select live public only"
  ON public.yakiimo_temp_logs
  FOR SELECT
  TO anon
  USING (
    session_id IN (
      SELECT session_id FROM public.yakiimo_sessions WHERE is_public = true
    )
  );

-- ============================================================================
-- Section 8: 既存 session の backfill
-- ============================================================================
-- デプロイ即時に live 表示が壊れぬよう、既存 yakiimo_temp_logs の全 session_id
-- を sessions に backfill。最新 1 件のみ is_public=true に設定 (排他保証)。

INSERT INTO public.yakiimo_sessions (session_id, started_at, ended_at)
SELECT
  session_id,
  MIN(measured_at) AS started_at,
  MAX(measured_at) AS ended_at
FROM public.yakiimo_temp_logs
GROUP BY session_id
ON CONFLICT (session_id) DO NOTHING;

-- 最新セッションのみ is_public=true (live 維持のため)
UPDATE public.yakiimo_sessions
   SET is_public = true
 WHERE session_id = (
   SELECT session_id FROM public.yakiimo_sessions
    ORDER BY ended_at DESC NULLS LAST LIMIT 1
 );

COMMIT;

-- ============================================================================
-- 動作確認用クエリ (Dashboard SQL Editor で実行可)
-- ============================================================================
--   -- sessions テーブル一覧 (公開状態確認)
--   SELECT session_id, display_name, purpose, is_public, started_at, ended_at
--     FROM public.yakiimo_sessions
--    ORDER BY ended_at DESC NULLS LAST;
--
--   -- 排他保証の確認 (常に 0 か 1 行)
--   SELECT count(*) FROM public.yakiimo_sessions WHERE is_public = true;
--
--   -- anon ポリシー一覧
--   SELECT polname, polcmd, polpermissive, polroles::regrole[]
--     FROM pg_policy
--    WHERE polrelid IN (
--      'public.yakiimo_sessions'::regclass,
--      'public.yakiimo_temp_logs'::regclass
--    )
--    ORDER BY polrelid::text, polname;
--
--   -- internal schema の関数一覧 (3 つあるはず)
--   SELECT n.nspname, p.proname, p.prosecdef
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'internal'
--    ORDER BY p.proname;

-- ============================================================================
-- ROLLBACK (実行不要・参考のみ)
-- ============================================================================
-- 004 を取り消して 001/002/003 の状態に戻す手順:
--
-- BEGIN;
-- DROP POLICY IF EXISTS "anon select live public only" ON public.yakiimo_temp_logs;
-- CREATE POLICY "anon select all" ON public.yakiimo_temp_logs FOR SELECT TO anon USING (true);
-- DROP TRIGGER IF EXISTS yakiimo_temp_logs_ensure_session ON public.yakiimo_temp_logs;
-- DROP TRIGGER IF EXISTS yakiimo_sessions_single_public ON public.yakiimo_sessions;
-- DROP TRIGGER IF EXISTS yakiimo_sessions_updated_at ON public.yakiimo_sessions;
-- DROP TABLE IF EXISTS public.yakiimo_sessions CASCADE;
-- DROP FUNCTION IF EXISTS internal.ensure_session_record();
-- DROP FUNCTION IF EXISTS internal.enforce_single_public_session();
-- DROP FUNCTION IF EXISTS internal.update_updated_at();
-- DROP SCHEMA IF EXISTS internal;
-- COMMIT;
