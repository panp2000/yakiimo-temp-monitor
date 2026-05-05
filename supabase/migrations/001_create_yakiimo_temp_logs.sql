-- yakiimo-temp-monitor: temperature logs table
-- Project: Supabase project (https://YOUR_PROJECT.supabase.co)
-- Run via: Supabase Dashboard → SQL Editor

CREATE TABLE IF NOT EXISTS public.yakiimo_temp_logs (
  id BIGSERIAL PRIMARY KEY,
  measured_at TIMESTAMPTZ NOT NULL,
  device_id TEXT NOT NULL DEFAULT 'esp32-01',
  session_id TEXT NOT NULL,
  channel TEXT NOT NULL,
  temp_c REAL,
  humidity_pct REAL,
  pressure_hpa REAL,
  raw JSONB,
  ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Channel allowed values (documented; not enforced as CHECK to keep flexibility):
--   'potato_internal'  K型熱電対 (CH0): やきいも内部
--   'potato_surface'   K型熱電対 (CH1): やきいも表面
--   'kiln_ambient'     K型熱電対 (CH2): 釜の雰囲気温度
--   'stone_surface'    K型熱電対 (CH3): 石の表面温度
--   'env'              BME280: 屋外の気温・湿度・気圧

CREATE INDEX IF NOT EXISTS yakiimo_temp_logs_session_measured_idx
  ON public.yakiimo_temp_logs (session_id, measured_at);

CREATE INDEX IF NOT EXISTS yakiimo_temp_logs_channel_measured_idx
  ON public.yakiimo_temp_logs (channel, measured_at DESC);

ALTER TABLE public.yakiimo_temp_logs ENABLE ROW LEVEL SECURITY;

-- ESP32 は anon key で INSERT のみ。既存行の SELECT/UPDATE/DELETE は許可しない。
-- (オーナーは Supabase ダッシュボードまたは service_role 経由で全件参照可能)
DROP POLICY IF EXISTS "anon insert only" ON public.yakiimo_temp_logs;
CREATE POLICY "anon insert only"
  ON public.yakiimo_temp_logs
  FOR INSERT
  TO anon
  WITH CHECK (true);

COMMENT ON TABLE public.yakiimo_temp_logs IS
  'やきいも下焼き工程の温度ログ。1秒/サンプル × 5チャンネル。ESP32+MAX31855×4+BME280。';
