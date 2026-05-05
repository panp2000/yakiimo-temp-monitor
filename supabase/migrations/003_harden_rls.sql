-- 003_harden_rls.sql
-- yakiimo_temp_logs テーブルの RLS 強化マイグレーション
-- Project: Supabase project (https://YOUR_PROJECT.supabase.co)
-- Run via: Supabase Dashboard → SQL Editor
--
-- (前提)
--   001 でテーブル作成と最低限 RLS (anon INSERT 無条件 WITH CHECK (true))。
--   002 で anon SELECT (USING (true)) を追加。
--   UPDATE / DELETE は現在ポリシー無し = 暗黙拒否。
--
-- (目的) anon key 流出時の汚染リスクを下げる。
--   1. INSERT に値検証 (channel ドメイン / device_id・session_id 形式 / 時刻範囲 / 物理レンジ)
--   2. UPDATE / DELETE は RESTRICTIVE で明示 deny (将来の事故耐性)
-- データ自体は非機密ゆえ SELECT 全行公開ポリシー (002) は維持。
--
-- (適用順序) 001 → 002 → 003 の順で適用。本ファイルは 003。
-- (適用方法) Supabase Dashboard SQL Editor で本ファイル全文貼付け実行、
--             または `supabase db push`。
-- (ロールバック) 末尾コメントの ROLLBACK セクション参照 (実行不要・参考のみ)。

BEGIN;

-- ============================================================================
-- Section 1: INSERT ポリシー強化 (R1)
-- ============================================================================
-- 旧ポリシー "anon insert only" は WITH CHECK (true) で無検証。
-- これを DROP し、値検証付きで CREATE し直す。
--   - channel: 既知ドメイン 5 値のみ許可
--   - device_id: 小文字英数字 + ハイフン + アンダースコア、1〜32 文字
--   - session_id: 英数字 + ハイフン + アンダースコア、1〜64 文字
--   - measured_at: 過去 1 日 〜 未来 1 時間以内 (時計ズレ許容しつつ過去/未来汚染を弾く)
--   - temp_c / humidity_pct / pressure_hpa: 物理レンジ (NULL は許容)

DROP POLICY IF EXISTS "anon insert only" ON public.yakiimo_temp_logs;
CREATE POLICY "anon insert only"
  ON public.yakiimo_temp_logs
  FOR INSERT
  TO anon
  WITH CHECK (
    channel IN ('potato_internal','potato_surface','kiln_ambient','stone_surface','env')
    AND device_id ~ '^[a-z0-9_-]{1,32}$'
    AND session_id ~ '^[a-zA-Z0-9_-]{1,64}$'
    AND measured_at > now() - interval '1 day'
    AND measured_at < now() + interval '1 hour'
    AND (temp_c IS NULL OR (temp_c >= -50 AND temp_c <= 1500))
    AND (humidity_pct IS NULL OR (humidity_pct >= 0 AND humidity_pct <= 100))
    AND (pressure_hpa IS NULL OR (pressure_hpa >= 800 AND pressure_hpa <= 1200))
  );

-- ============================================================================
-- Section 2: UPDATE / DELETE 明示 RESTRICTIVE deny (R2)
-- ============================================================================
-- 現状「ポリシー無し = 暗黙拒否」だが、将来の事故 (例: 別マイグレーションで
-- FOR ALL TO anon ポリシーを誤投入) で開いてしまう懸念がある。
-- RESTRICTIVE は他ポリシーと AND 結合されるため、anon の UPDATE/DELETE を
-- 必ず拒否する事故耐性が得られる (ベルト+サスペンダー)。

DROP POLICY IF EXISTS "anon no update" ON public.yakiimo_temp_logs;
CREATE POLICY "anon no update"
  ON public.yakiimo_temp_logs
  AS RESTRICTIVE
  FOR UPDATE
  TO anon
  USING (false);

DROP POLICY IF EXISTS "anon no delete" ON public.yakiimo_temp_logs;
CREATE POLICY "anon no delete"
  ON public.yakiimo_temp_logs
  AS RESTRICTIVE
  FOR DELETE
  TO anon
  USING (false);

COMMIT;

-- ============================================================================
-- 動作確認用クエリ (Dashboard SQL Editor で実行可)
-- ============================================================================
--   -- 現在のポリシー一覧を確認
--   SELECT polname, polcmd, polpermissive, polroles::regrole[]
--     FROM pg_policy
--    WHERE polrelid = 'public.yakiimo_temp_logs'::regclass
--    ORDER BY polname;
--
--   -- 不正値 INSERT が拒否されることを確認 (anon ロールで実行)
--   --   channel='admin'             -> 拒否
--   --   temp_c=9999                 -> 拒否
--   --   measured_at='2030-01-01'    -> 拒否

-- ============================================================================
-- ROLLBACK (実行不要・参考のみ)
-- ============================================================================
-- 003 を取り消して 001/002 の状態に戻す手順:
--
-- BEGIN;
--
-- -- Section 2 を取り消し (RESTRICTIVE deny ポリシーを削除)
-- DROP POLICY IF EXISTS "anon no update" ON public.yakiimo_temp_logs;
-- DROP POLICY IF EXISTS "anon no delete" ON public.yakiimo_temp_logs;
--
-- -- Section 1 を取り消し (INSERT ポリシーを 001 の無条件版に戻す)
-- DROP POLICY IF EXISTS "anon insert only" ON public.yakiimo_temp_logs;
-- CREATE POLICY "anon insert only"
--   ON public.yakiimo_temp_logs
--   FOR INSERT
--   TO anon
--   WITH CHECK (true);
--
-- COMMIT;
