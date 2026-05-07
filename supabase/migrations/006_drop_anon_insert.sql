-- 006_drop_anon_insert.sql
-- anon INSERT ポリシーを撤去 (Phase 8-C)
--
-- (前提)
--   001 で anon insert (WITH CHECK true) 設定。
--   003 で WITH CHECK 値検証付きに強化。
--   Phase 8-A/B で ESP32 が Cloudflare Worker (HMAC 認証) 経由 INSERT に切替完了。
--
-- (戦略文脈)
--   ESP32 は Worker 経由 (service_role) で INSERT、anon key の INSERT 権限は不要に。
--   anon key 漏洩 (公開ダッシュボード JS / ESP32 ファーム抽出) によるスパム書込
--   経路を構造的に消滅させる。anon key は SELECT (公開セッションの読込) 専用。
--
-- (適用順序) 001 → 002 → 003 → 004 → 005 → 006。本ファイルは 006。
-- (適用方法) Supabase Dashboard SQL Editor、または MCP execute_sql。
-- (ロールバック) 末尾コメント参照 (003 の WITH CHECK 付きポリシーを再作成)。

BEGIN;

-- ============================================================================
-- Section 1: anon insert ポリシー撤去
-- ============================================================================

DROP POLICY IF EXISTS "anon insert only" ON public.yakiimo_temp_logs;

COMMIT;

-- ============================================================================
-- 動作確認 (適用後の期待挙動)
-- ============================================================================
--   -- anon ロールで INSERT 試行 → 失敗期待 (RLS 拒否)
--   SET ROLE anon;
--   INSERT INTO public.yakiimo_temp_logs (device_id, session_id, measured_at, channel, temp_c)
--   VALUES ('attack-test', 'attack-session', now(), 'env', 25);
--   -- ERROR: new row violates row-level security policy
--   RESET ROLE;
--
--   -- service_role 経由 (Worker) は引き続き INSERT 可
--   -- (Worker のリアル動作確認は admin 画面でデータ流入を見ればよい)
--
--   -- 残存ポリシー確認
--   SELECT polname, polcmd, polpermissive, polroles::regrole[]
--     FROM pg_policy
--    WHERE polrelid = 'public.yakiimo_temp_logs'::regclass
--    ORDER BY polname;
--   -- INSERT ポリシーが消え、UPDATE/DELETE の RESTRICTIVE deny + SELECT live public のみ残るはず

-- ============================================================================
-- ROLLBACK (実行不要・参考のみ)
-- ============================================================================
-- 006 を取消し anon INSERT を復活させる手順 (003 の WITH CHECK 仕様を再現):
--
-- BEGIN;
-- CREATE POLICY "anon insert only"
--   ON public.yakiimo_temp_logs
--   FOR INSERT
--   TO anon
--   WITH CHECK (
--     channel IN ('potato_internal','potato_surface','kiln_ambient','stone_surface','env')
--     AND device_id ~ '^[a-z0-9_-]{1,32}$'
--     AND session_id ~ '^[a-zA-Z0-9_-]{1,64}$'
--     AND measured_at > now() - interval '1 day'
--     AND measured_at < now() + interval '1 hour'
--     AND (temp_c IS NULL OR (temp_c >= -50 AND temp_c <= 1500))
--     AND (humidity_pct IS NULL OR (humidity_pct >= 0 AND humidity_pct <= 100))
--     AND (pressure_hpa IS NULL OR (pressure_hpa >= 800 AND pressure_hpa <= 1200))
--   );
-- COMMIT;
