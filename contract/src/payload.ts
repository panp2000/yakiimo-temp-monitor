// Yakiimo Ingest Contract — Payload Schema (LogRow 値域)

export const CHANNELS = [
  "potato_internal",
  "potato_surface",
  "kiln_ambient",
  "stone_surface",
  "env",
] as const;
export type Channel = typeof CHANNELS[number];

export const DEVICE_ID_REGEX = /^[a-z0-9_-]{1,32}$/;
export const SESSION_ID_REGEX = /^[a-zA-Z0-9_-]{1,64}$/;

export const TEMP_C_RANGE = { min: -50, max: 1500 } as const;
export const HUMIDITY_PCT_RANGE = { min: 0, max: 100 } as const;
export const PRESSURE_HPA_RANGE = { min: 800, max: 1200 } as const;

/**
 * measured_at の許容ウィンドウ。RLS / DB trigger が SQL interval として消費する。
 */
export const MEASURED_AT_PAST_INTERVAL = "1 day";
export const MEASURED_AT_FUTURE_INTERVAL = "1 hour";

export interface LogRow {
  device_id: string;
  session_id: string;
  measured_at: string; // ISO 8601 UTC
  channel: Channel;
  temp_c: number | null;
  humidity_pct: number | null;
  pressure_hpa: number | null;
}

export type PayloadValidationError =
  | { field: "device_id"; reason: "regex_mismatch" }
  | { field: "session_id"; reason: "regex_mismatch" }
  | { field: "measured_at"; reason: "not_iso8601" }
  | { field: "channel"; reason: "not_in_domain" }
  | { field: "temp_c"; reason: "out_of_range" }
  | { field: "humidity_pct"; reason: "out_of_range" }
  | { field: "pressure_hpa"; reason: "out_of_range" };

export type ValidateLogRowResult =
  | { ok: true; row: LogRow }
  | { ok: false; errors: PayloadValidationError[] };

export function validateLogRow(input: unknown): ValidateLogRowResult {
  const errors: PayloadValidationError[] = [];

  if (typeof input !== "object" || input === null) {
    return { ok: false, errors: [{ field: "device_id", reason: "regex_mismatch" }] };
  }
  const r = input as Record<string, unknown>;

  // device_id
  if (typeof r.device_id !== "string" || !DEVICE_ID_REGEX.test(r.device_id)) {
    errors.push({ field: "device_id", reason: "regex_mismatch" });
  }
  // session_id
  if (typeof r.session_id !== "string" || !SESSION_ID_REGEX.test(r.session_id)) {
    errors.push({ field: "session_id", reason: "regex_mismatch" });
  }
  // measured_at: ISO 8601 UTC を素朴チェック (Z 終端)
  if (typeof r.measured_at !== "string" || !isIso8601Utc(r.measured_at)) {
    errors.push({ field: "measured_at", reason: "not_iso8601" });
  }
  // channel
  if (typeof r.channel !== "string" || !(CHANNELS as readonly string[]).includes(r.channel)) {
    errors.push({ field: "channel", reason: "not_in_domain" });
  }
  // temp_c
  if (!isNullableNumberInRange(r.temp_c, TEMP_C_RANGE)) {
    errors.push({ field: "temp_c", reason: "out_of_range" });
  }
  // humidity_pct
  if (!isNullableNumberInRange(r.humidity_pct, HUMIDITY_PCT_RANGE)) {
    errors.push({ field: "humidity_pct", reason: "out_of_range" });
  }
  // pressure_hpa
  if (!isNullableNumberInRange(r.pressure_hpa, PRESSURE_HPA_RANGE)) {
    errors.push({ field: "pressure_hpa", reason: "out_of_range" });
  }

  if (errors.length > 0) return { ok: false, errors };
  return { ok: true, row: r as unknown as LogRow };
}

function isIso8601Utc(s: string): boolean {
  // 簡素な checker: YYYY-MM-DDTHH:MM:SS(.fraction)?Z
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(s);
}

function isNullableNumberInRange(v: unknown, range: { min: number; max: number }): boolean {
  if (v === null) return true;
  if (typeof v !== "number" || !Number.isFinite(v)) return false;
  return v >= range.min && v <= range.max;
}
