-- yakiimo-temp-monitor: anon に SELECT 権限を追加
-- Project: Supabase project (https://YOUR_PROJECT.supabase.co)
-- Run via: Supabase Dashboard → SQL Editor
--
-- 背景:
-- 001 で anon は INSERT のみ可とした。Phase 2 で Cloudflare Pages にダッシュボードを置き、
-- ブラウザから anon key で時系列データを読む必要が生じたため SELECT 権限を追加する。
--
-- セキュリティ判断:
-- 焼き芋の温度データは非機密(個人情報・財務情報等を含まず、漏洩しても実害なし)。
-- ダッシュボード URL を知る者は誰でも閲覧可、というモデルを許容する。
-- 公開を望まぬデータが将来含まれる場合は、別テーブルに分離するか auth ロール導入を検討。
--
-- 既存ポリシー (確認用):
--   "anon insert only" — INSERT 専用、WITH CHECK (true)
--
-- このマイグレーションで追加するポリシー:
--   "anon select all" — SELECT 専用、USING (true)
--
-- UPDATE / DELETE は引き続き anon に許可しない (ポリシー無し = 暗黙拒否)。
-- 投入済みデータの改竄・削除は service_role 経由 or Dashboard でのみ可能。

DROP POLICY IF EXISTS "anon select all" ON public.yakiimo_temp_logs;
CREATE POLICY "anon select all"
  ON public.yakiimo_temp_logs
  FOR SELECT
  TO anon
  USING (true);

-- 動作確認用クエリ (Dashboard SQL Editor で実行可):
--   SELECT count(*) FROM public.yakiimo_temp_logs;
--   SELECT * FROM public.yakiimo_temp_logs ORDER BY measured_at DESC LIMIT 10;
