import type { ChartDataset } from "chart.js";
import { CHANNEL_DISPLAY } from "./channels.js";
import { median3Filter, type XYPoint } from "./median.js";
import type { Channel } from "@yakiimo/contract/payload";

export interface LogPoint {
  channel: Channel;
  measured_at: string;
  temp_c: number | null;
}

export interface BuildDatasetsOptions {
  resolveColor: (channelKey: Channel) => string;
  applyMedian?: boolean;            // default true
  bgAlphaHex?: string;              // default "1a" (10%)
  baseDatasetOptions?: Record<string, unknown>;  // borderWidth/pointRadius 等
}

/**
 * logs を channel ごとに group → 必要なら median3 を適用 → CHANNEL_DISPLAY 順序で
 * Chart.js dataset 配列に変換する純関数。
 *
 * resolveColor は呼び側 (live / admin) が wire する DOM 依存ロジック。
 * dashboard-shared 自体は jsdom 不要で純関数として vitest 可能。
 */
export function buildDatasets(
  logs: ReadonlyArray<LogPoint>,
  opts: BuildDatasetsOptions
): ChartDataset<"line", XYPoint[]>[] {
  const applyMedian = opts.applyMedian !== false; // default true
  const bgAlphaHex = opts.bgAlphaHex ?? "1a";
  const baseDatasetOptions = opts.baseDatasetOptions ?? {};

  // channel 別に group (CHANNEL_DISPLAY 順序を維持)
  const grouped = new Map<Channel, XYPoint[]>();
  for (const ch of CHANNEL_DISPLAY) {
    grouped.set(ch.key, []);
  }
  for (const log of logs) {
    const arr = grouped.get(log.channel);
    if (!arr) continue; // CHANNEL_DISPLAY に無い channel は無視
    arr.push({
      x: new Date(log.measured_at).getTime(),
      y: log.temp_c,
    });
  }

  return CHANNEL_DISPLAY.map((ch) => {
    const raw = grouped.get(ch.key) ?? [];
    const data = applyMedian ? median3Filter(raw) : raw.slice();
    const color = opts.resolveColor(ch.key);
    return {
      label: ch.label,
      data,
      borderColor: color,
      backgroundColor: color + bgAlphaHex,
      ...baseDatasetOptions,
    } as ChartDataset<"line", XYPoint[]>;
  });
}
