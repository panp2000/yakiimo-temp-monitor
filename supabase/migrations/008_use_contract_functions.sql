-- 008_use_contract_functions.sql
-- yakiimo_temp_logs に contract validation BEFORE INSERT trigger を追加 (Stage 9-F)
--
-- (前提)
--   001-006 で table / RLS / pg_cron / anon INSERT 撤去まで完了。
--   007 で contract validator 関数群 (internal.yakiimo_valid_*) を登録済。
--
-- (戦略文脈)
--   Defense in Depth Layer 3: 全ロール (service_role 含む) に contract 違反を
--   通さない最終ゲート。Worker bug / admin 直接 INSERT のいずれの経路でも
--   contract 関数による validation が走る。
--
-- (適用順序) 001 → 002 → 003 → 004 → 005 → 006 → 007 → 008。本ファイルは 008。
-- (適用方法) Supabase Dashboard SQL Editor、または MCP execute_sql。
-- (ロールバック) 末尾コメント参照 (trigger と function を DROP)。

BEGIN;

-- ============================================================================
-- Section 1: trigger 関数 (各 contract validator を順次呼ぶ)
-- ============================================================================
-- 違反項目を ERRCODE 23514 (check_violation) で raise、原因 column 名を表示。

CREATE OR REPLACE FUNCTION internal.yakiimo_temp_logs_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, internal, pg_temp
AS $$
BEGIN
  IF NOT internal.yakiimo_valid_channel(NEW.channel) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid channel %', NEW.channel
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_device_id(NEW.device_id) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid device_id %', NEW.device_id
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_session_id(NEW.session_id) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid session_id %', NEW.session_id
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_measured_at(NEW.measured_at) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid measured_at %', NEW.measured_at
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_temp(NEW.temp_c) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid temp_c %', NEW.temp_c
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_humidity(NEW.humidity_pct) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid humidity_pct %', NEW.humidity_pct
      USING ERRCODE = '23514';
  END IF;
  IF NOT internal.yakiimo_valid_pressure(NEW.pressure_hpa) THEN
    RAISE EXCEPTION 'yakiimo contract: invalid pressure_hpa %', NEW.pressure_hpa
      USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================================
-- Section 2: BEFORE INSERT trigger
-- ============================================================================
-- BEFORE INSERT のみ (UPDATE は付けない、admin の事後修正で古い measured_at
-- が validation に引っかかるのを避ける)。

DROP TRIGGER IF EXISTS yakiimo_temp_logs_validate_trigger ON public.yakiimo_temp_logs;

CREATE TRIGGER yakiimo_temp_logs_validate_trigger
  BEFORE INSERT ON public.yakiimo_temp_logs
  FOR EACH ROW EXECUTE FUNCTION internal.yakiimo_temp_logs_validate();

COMMIT;

-- ============================================================================
-- 動作確認 (適用後の期待挙動)
-- ============================================================================
--   -- service_role でも違反は拒否される
--   INSERT INTO public.yakiimo_temp_logs (device_id, session_id, measured_at, channel, temp_c)
--   VALUES ('admin-test', 'attack-2026-05-07', now(), 'invalid_channel', 25);
--   -- ERROR: 23514: yakiimo contract: invalid channel invalid_channel
--
--   -- 正規データは通過
--   INSERT INTO public.yakiimo_temp_logs (device_id, session_id, measured_at, channel, temp_c)
--   VALUES ('esp32-01', 'test-9f', now(), 'env', 25);
--   -- INSERT 0 1

-- ============================================================================
-- ROLLBACK (実行不要・参考のみ)
-- ============================================================================
-- BEGIN;
-- DROP TRIGGER IF EXISTS yakiimo_temp_logs_validate_trigger ON public.yakiimo_temp_logs;
-- DROP FUNCTION IF EXISTS internal.yakiimo_temp_logs_validate();
-- COMMIT;
