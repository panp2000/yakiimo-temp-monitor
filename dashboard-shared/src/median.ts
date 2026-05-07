// 3点中央値フィルタ (表示用、データ層は無加工)
// MAX31855 の量子化ジッタ (±0.25°C / 1 LSB) を視覚的に除去するためにのみ使う。
// 入力: [{x: ts, y: val}, ...] 形式の配列 (生データ)
// 出力: 同形式・同長の新配列。各 y は自身 + 前後 1 点の中央値。
// 両端 (i=0, i=末尾) は隣接 1 点との 2 値だけで中央値を取る (= 平均と等価)。
// 中央値ゆえ平均フィルタのような遅延は発生せず、急変への追従性は維持される。

export interface XYPoint {
  x: number;
  y: number | null;
}

export function median3Filter(points: ReadonlyArray<XYPoint>): XYPoint[] {
  if (!points || points.length < 3) {
    return points ? points.slice() : [];
  }
  const out: XYPoint[] = new Array(points.length);
  for (let i = 0; i < points.length; i++) {
    const a = points[Math.max(0, i - 1)].y;
    const b = points[i].y;
    const c = points[Math.min(points.length - 1, i + 1)].y;
    const sorted = [a, b, c]
      .filter((v): v is number => v !== null && !Number.isNaN(v as number))
      .sort((x, y) => x - y);
    out[i] = {
      x: points[i].x,
      y: sorted.length === 0 ? null : sorted[Math.floor(sorted.length / 2)],
    };
  }
  return out;
}
