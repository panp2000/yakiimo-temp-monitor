-- 005_setup_auto_close_cron.sql
-- yakiimo_sessions.is_public を idle 経過で自動 false 化する pg_cron schedule
--
-- (前提)
--   001-004 で yakiimo_temp_logs / yakiimo_sessions / RLS / 排他保証が整備済。
--   yakiimo_sessions.ended_at は yakiimo_temp_logs INSERT 時にトリガで自動更新。
--
-- (戦略文脈)
--   オーナーが焼成終了後に手動で is_public=false を戻し忘れた場合、
--   過去セッションのデータが anon に公開され続けるのを防ぐ自動化。
--   5 分毎に走査し、最終データから 30 分超経過した public セッションを false 化。
--
-- (適用順序) 001 → 002 → 003 → 004 → 005。本ファイルは 005。
-- (適用方法) Supabase Dashboard SQL Editor か MCP execute_sql。
-- (ロールバック) 末尾コメントの ROLLBACK セクション参照。
--
-- (前提環境) Supabase 無料枠で pg_cron は標準サポート (extension 有効化が必要)。

BEGIN;

-- ============================================================================
-- Section 1: pg_cron extension 有効化
-- ============================================================================
-- 共用 project (MyCompany 等) で既に有効ならスキップ。

CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ============================================================================
-- Section 2: 既存 schedule の冪等削除
-- ============================================================================
-- 同名 job が既にあれば消す。無ければ何もしない (DO ブロックで例外握りつぶし)。

DO $$
BEGIN
  PERFORM cron.unschedule('yakiimo_auto_close_idle_sessions');
EXCEPTION WHEN OTHERS THEN
  NULL;
END $$;

-- ============================================================================
-- Section 3: schedule 登録
-- ============================================================================
-- 5 分毎、最終データから 30 分超経過した public セッションを false 化。

SELECT cron.schedule(
  'yakiimo_auto_close_idle_sessions',
  '*/5 * * * *',
  $cmd$
    UPDATE public.yakiimo_sessions
       SET is_public = false,
           updated_at = now()
     WHERE is_public = true
       AND ended_at < now() - interval '30 minutes';
  $cmd$
);

COMMIT;

-- ============================================================================
-- 動作確認用クエリ
-- ============================================================================
-- 登録済 cron job 一覧:
--   SELECT jobid, jobname, schedule, command, active
--     FROM cron.job
--    WHERE jobname = 'yakiimo_auto_close_idle_sessions';
--
-- 直近の実行履歴 (job が走った時刻と結果):
--   SELECT jobid, runid, job_pid, database, username, command, status, return_message,
--          start_time, end_time
--     FROM cron.job_run_details
--    WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'yakiimo_auto_close_idle_sessions')
--    ORDER BY start_time DESC
--    LIMIT 10;
--
-- 手動テスト (今すぐ flip 確認):
--   UPDATE public.yakiimo_sessions SET ended_at = now() - interval '31 minutes'
--    WHERE session_id = '<対象 session_id>' AND is_public = true;
--   -- 5 分以内に cron が走り is_public=false になるはず

-- ============================================================================
-- ROLLBACK (実行不要・参考のみ)
-- ============================================================================
-- BEGIN;
-- SELECT cron.unschedule('yakiimo_auto_close_idle_sessions');
-- -- pg_cron extension 自体は他テーブルでも使う可能性があるため DROP EXTENSION しない。
-- COMMIT;
