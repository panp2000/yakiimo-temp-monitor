import { describe, it, expect } from "vitest";
import { CHANNELS } from "@yakiimo/contract/payload";
import { CHANNEL_DISPLAY } from "../src/channels.js";

describe("CHANNEL_DISPLAY <-> contract CHANNELS の集合一致", () => {
  it("CHANNEL_DISPLAY の key 集合が contract CHANNELS と一致する", () => {
    const fromContract = new Set(CHANNELS);
    const fromDisplay = new Set(CHANNEL_DISPLAY.map((c) => c.key));

    // 双方向の差分をゼロに
    for (const key of fromContract) {
      expect(fromDisplay.has(key)).toBe(true);
    }
    for (const key of fromDisplay) {
      expect(fromContract.has(key)).toBe(true);
    }
    expect(fromDisplay.size).toBe(fromContract.size);
  });

  it("CHANNEL_DISPLAY 各エントリが label / icon / varName を持つ", () => {
    for (const ch of CHANNEL_DISPLAY) {
      expect(typeof ch.key).toBe("string");
      expect(typeof ch.label).toBe("string");
      expect(ch.label.length).toBeGreaterThan(0);
      expect(typeof ch.icon).toBe("string");
      expect(ch.icon.length).toBeGreaterThan(0);
      expect(ch.varName.startsWith("--color-ch-")).toBe(true);
    }
  });
});
