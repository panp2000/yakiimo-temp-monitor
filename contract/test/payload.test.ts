import { describe, it, expect } from "vitest";
import { validateLogRow, CHANNELS } from "../src/payload.js";

describe("validateLogRow", () => {
  const VALID_BASE = {
    device_id: "esp32-01",
    session_id: "2026-05-07-test",
    measured_at: "2026-05-07T01:23:45Z",
    channel: "potato_internal" as const,
    temp_c: 250.5,
    humidity_pct: null,
    pressure_hpa: null,
  };

  it("accepts a fully valid row", () => {
    const result = validateLogRow(VALID_BASE);
    expect(result.ok).toBe(true);
  });

  it("accepts env channel with humidity & pressure", () => {
    const result = validateLogRow({
      ...VALID_BASE,
      channel: "env",
      temp_c: 22.0,
      humidity_pct: 45.5,
      pressure_hpa: 1013.25,
    });
    expect(result.ok).toBe(true);
  });

  it("accepts null temp_c", () => {
    const result = validateLogRow({ ...VALID_BASE, temp_c: null });
    expect(result.ok).toBe(true);
  });

  it("rejects invalid device_id (uppercase)", () => {
    const result = validateLogRow({ ...VALID_BASE, device_id: "ESP32-01" });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.errors).toContainEqual({ field: "device_id", reason: "regex_mismatch" });
    }
  });

  it("rejects invalid session_id (with space)", () => {
    const result = validateLogRow({ ...VALID_BASE, session_id: "bad session" });
    expect(result.ok).toBe(false);
  });

  it("rejects measured_at without Z suffix", () => {
    const result = validateLogRow({ ...VALID_BASE, measured_at: "2026-05-07T01:23:45" });
    expect(result.ok).toBe(false);
  });

  it("rejects channel not in CHANNELS", () => {
    const result = validateLogRow({ ...VALID_BASE, channel: "potato_top" as never });
    expect(result.ok).toBe(false);
  });

  it("rejects temp_c out of range (too high)", () => {
    const result = validateLogRow({ ...VALID_BASE, temp_c: 1501 });
    expect(result.ok).toBe(false);
  });

  it("rejects humidity_pct out of range", () => {
    const result = validateLogRow({ ...VALID_BASE, channel: "env", humidity_pct: 101 });
    expect(result.ok).toBe(false);
  });

  it("rejects pressure_hpa out of range (too low)", () => {
    const result = validateLogRow({ ...VALID_BASE, channel: "env", pressure_hpa: 700 });
    expect(result.ok).toBe(false);
  });

  it("rejects non-object input", () => {
    const result = validateLogRow(null);
    expect(result.ok).toBe(false);
  });

  it("CHANNELS is exactly 5 known values", () => {
    expect(CHANNELS).toEqual([
      "potato_internal",
      "potato_surface",
      "kiln_ambient",
      "stone_surface",
      "env",
    ]);
  });
});
