-- yakiimo-temp-monitor / Phase 14-A: replay dedup (THREAT-MODEL.md gap 4)
--
-- yakiimo_temp_logs に (device_id, session_id, channel, measured_at) の
-- UNIQUE 制約を追加し、同一 measurement の重複 INSERT を DB 層で阻止する。
-- Worker 側は Prefer: resolution=ignore-duplicates を併用して
-- conflict 発生時を silent OK 扱いにする (idempotent INSERT)。
--
-- HMAC envelope の timestamp tolerance (past 300s / future 60s) 内に
-- 同一 body の重複 POST が発生しても、本制約 + Worker の Prefer により
-- 重複行は記録されず、応答も成功扱いになる。

BEGIN;

ALTER TABLE public.yakiimo_temp_logs
  ADD CONSTRAINT yakiimo_temp_logs_unique_measurement
  UNIQUE (device_id, session_id, channel, measured_at);

COMMIT;

-- ROLLBACK (実行不要・参考):
-- BEGIN;
-- ALTER TABLE public.yakiimo_temp_logs
--   DROP CONSTRAINT IF EXISTS yakiimo_temp_logs_unique_measurement;
-- COMMIT;
