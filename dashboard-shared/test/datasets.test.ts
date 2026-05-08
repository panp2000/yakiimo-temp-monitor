import { describe, it, expect, vi } from "vitest";
import { buildDatasets, type LogPoint } from "../src/datasets.js";
import { CHANNEL_DISPLAY } from "../src/channels.js";
import type { Channel } from "@yakiimo/contract/payload";

const ALL_CHANNELS: Channel[] = [
  "potato_internal",
  "potato_surface",
  "kiln_ambient",
  "stone_surface",
  "env",
];

function makeLog(channel: Channel, iso: string, temp: number | null): LogPoint {
  return { channel, measured_at: iso, temp_c: temp };
}

function fakeColor(channel: Channel): string {
  const map: Record<Channel, string> = {
    potato_internal: "#a83a2c",
    potato_surface: "#d97757",
    kiln_ambient: "#dba521",
    stone_surface: "#888888",
    env: "#3a8fb7",
  };
  return map[channel];
}

describe("buildDatasets", () => {
  it("CHANNEL_DISPLAY の順序を維持し dataset 配列を返す", () => {
    const logs: LogPoint[] = [];
    const datasets = buildDatasets(logs, { resolveColor: fakeColor });
    expect(datasets.length).toBe(CHANNEL_DISPLAY.length);
    for (let i = 0; i < datasets.length; i++) {
      expect(datasets[i].label).toBe(CHANNEL_DISPLAY[i].label);
    }
  });

  it("resolveColor が CHANNEL_DISPLAY の各 channel について 1 度ずつ呼ばれる", () => {
    const resolveColor = vi.fn((c: Channel) => fakeColor(c));
    buildDatasets([], { resolveColor });
    expect(resolveColor).toHaveBeenCalledTimes(CHANNEL_DISPLAY.length);
    const calledKeys = resolveColor.mock.calls.map((c) => c[0]);
    for (const ch of CHANNEL_DISPLAY) {
      expect(calledKeys.filter((k) => k === ch.key).length).toBe(1);
    }
  });

  it("borderColor は resolveColor の戻り値、backgroundColor は color + bgAlphaHex", () => {
    const datasets = buildDatasets([], { resolveColor: fakeColor });
    for (const ds of datasets) {
      expect(typeof ds.borderColor).toBe("string");
      // backgroundColor は borderColor + "1a" (default)
      expect((ds.backgroundColor as string).endsWith("1a")).toBe(true);
      expect((ds.backgroundColor as string).startsWith(ds.borderColor as string)).toBe(true);
    }
  });

  it("bgAlphaHex を反映する", () => {
    const datasets = buildDatasets([], {
      resolveColor: fakeColor,
      bgAlphaHex: "33",
    });
    for (const ds of datasets) {
      expect((ds.backgroundColor as string).endsWith("33")).toBe(true);
    }
  });

  it("applyMedian=false で median 非適用 (生データそのまま)", () => {
    // potato_internal に sharp spike を入れる: 10, 999, 12
    // median3 適用なら spike が均される (i=1 → median(10,999,12)=12)
    // applyMedian=false なら 999 がそのまま残る
    const logs: LogPoint[] = [
      makeLog("potato_internal", "2026-05-07T00:00:00Z", 10),
      makeLog("potato_internal", "2026-05-07T00:00:01Z", 999),
      makeLog("potato_internal", "2026-05-07T00:00:02Z", 12),
    ];

    const dsRaw = buildDatasets(logs, { resolveColor: fakeColor, applyMedian: false });
    const internalRaw = dsRaw.find((d) => d.label === "アルミホイル 内部")!;
    expect(internalRaw.data.map((p) => p.y)).toEqual([10, 999, 12]);

    const dsMed = buildDatasets(logs, { resolveColor: fakeColor, applyMedian: true });
    const internalMed = dsMed.find((d) => d.label === "アルミホイル 内部")!;
    // i=1 で median(10, 999, 12) = 12 なので spike が消える
    expect(internalMed.data.map((p) => p.y)).toEqual([10, 12, 12]);
  });

  it("applyMedian default は true", () => {
    const logs: LogPoint[] = [
      makeLog("potato_internal", "2026-05-07T00:00:00Z", 10),
      makeLog("potato_internal", "2026-05-07T00:00:01Z", 999),
      makeLog("potato_internal", "2026-05-07T00:00:02Z", 12),
    ];
    const ds = buildDatasets(logs, { resolveColor: fakeColor });
    const internal = ds.find((d) => d.label === "アルミホイル 内部")!;
    expect(internal.data.map((p) => p.y)).toEqual([10, 12, 12]);
  });

  it("baseDatasetOptions が dataset に展開される", () => {
    const datasets = buildDatasets([], {
      resolveColor: fakeColor,
      baseDatasetOptions: { borderWidth: 2, pointRadius: 0 },
    });
    for (const ds of datasets) {
      expect((ds as unknown as { borderWidth: number }).borderWidth).toBe(2);
      expect((ds as unknown as { pointRadius: number }).pointRadius).toBe(0);
    }
  });

  it("logs を channel ごとに正しく group する", () => {
    const logs: LogPoint[] = [
      makeLog("potato_internal", "2026-05-07T00:00:00Z", 100),
      makeLog("env", "2026-05-07T00:00:00Z", 25),
      makeLog("potato_internal", "2026-05-07T00:00:01Z", 101),
      makeLog("env", "2026-05-07T00:00:01Z", 26),
    ];
    const ds = buildDatasets(logs, { resolveColor: fakeColor, applyMedian: false });
    const internal = ds.find((d) => d.label === "アルミホイル 内部")!;
    const env = ds.find((d) => d.label === "気温")!;
    expect(internal.data.length).toBe(2);
    expect(env.data.length).toBe(2);
    expect(internal.data.map((p) => p.y)).toEqual([100, 101]);
    expect(env.data.map((p) => p.y)).toEqual([25, 26]);
    // 他の channel は空
    for (const ch of ALL_CHANNELS) {
      if (ch === "potato_internal" || ch === "env") continue;
      const display = CHANNEL_DISPLAY.find((c) => c.key === ch)!;
      const dsForCh = ds.find((d) => d.label === display.label)!;
      expect(dsForCh.data.length).toBe(0);
    }
  });
});
