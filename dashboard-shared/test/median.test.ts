import { describe, it, expect } from "vitest";
import { median3Filter, type XYPoint } from "../src/median.js";

describe("median3Filter", () => {
  it("空配列を空配列で返す", () => {
    expect(median3Filter([])).toEqual([]);
  });

  it("長さ 1 はそのまま slice で返す (新しい配列)", () => {
    const input: XYPoint[] = [{ x: 1, y: 10 }];
    const out = median3Filter(input);
    expect(out).toEqual([{ x: 1, y: 10 }]);
    expect(out).not.toBe(input); // slice で新配列
  });

  it("長さ 2 はそのまま slice で返す", () => {
    const input: XYPoint[] = [
      { x: 1, y: 10 },
      { x: 2, y: 20 },
    ];
    const out = median3Filter(input);
    expect(out).toEqual([
      { x: 1, y: 10 },
      { x: 2, y: 20 },
    ]);
    expect(out).not.toBe(input);
  });

  it("通常 5 点で各点が前後との中央値になる", () => {
    const input: XYPoint[] = [
      { x: 1, y: 1 },
      { x: 2, y: 5 },
      { x: 3, y: 2 },
      { x: 4, y: 8 },
      { x: 5, y: 3 },
    ];
    // 期待値:
    // i=0: a=1(self), b=1, c=5  → sorted=[1,1,5] → median=1
    // i=1: a=1, b=5, c=2        → sorted=[1,2,5] → median=2
    // i=2: a=5, b=2, c=8        → sorted=[2,5,8] → median=5
    // i=3: a=2, b=8, c=3        → sorted=[2,3,8] → median=3
    // i=4: a=8, b=3, c=3(self)  → sorted=[3,3,8] → median=3
    const out = median3Filter(input);
    expect(out).toEqual([
      { x: 1, y: 1 },
      { x: 2, y: 2 },
      { x: 3, y: 5 },
      { x: 4, y: 3 },
      { x: 5, y: 3 },
    ]);
  });

  it("null 混在 — null は中央値計算から除外され、残った中の中央値を採る", () => {
    const input: XYPoint[] = [
      { x: 1, y: 10 },
      { x: 2, y: null },
      { x: 3, y: 30 },
      { x: 4, y: 20 },
    ];
    // i=0: [10,10,null] → filtered=[10,10] → median=10
    // i=1: [10,null,30] → filtered=[10,30] → median (Math.floor(2/2)=1) = 30
    // i=2: [null,30,20] → filtered=[30,20] sorted=[20,30] → median (idx 1) = 30
    // i=3: [30,20,20]   → sorted=[20,20,30] → median=20
    const out = median3Filter(input);
    expect(out).toEqual([
      { x: 1, y: 10 },
      { x: 2, y: 30 },
      { x: 3, y: 30 },
      { x: 4, y: 20 },
    ]);
  });

  it("全点 null なら全 y が null", () => {
    const input: XYPoint[] = [
      { x: 1, y: null },
      { x: 2, y: null },
      { x: 3, y: null },
    ];
    expect(median3Filter(input)).toEqual([
      { x: 1, y: null },
      { x: 2, y: null },
      { x: 3, y: null },
    ]);
  });

  it("NaN 混在 — NaN は除外される", () => {
    const input: XYPoint[] = [
      { x: 1, y: 10 },
      { x: 2, y: NaN },
      { x: 3, y: 30 },
    ];
    // i=0: [10,10,NaN] → filtered=[10,10] → median=10
    // i=1: [10,NaN,30] → filtered=[10,30] → median (idx 1) = 30
    // i=2: [NaN,30,30] → filtered=[30,30] → median (idx 1) = 30
    const out = median3Filter(input);
    expect(out).toEqual([
      { x: 1, y: 10 },
      { x: 2, y: 30 },
      { x: 3, y: 30 },
    ]);
  });

  it("x 値は維持される (y のみ書き換わる)", () => {
    const input: XYPoint[] = [
      { x: 100, y: 1 },
      { x: 200, y: 2 },
      { x: 300, y: 3 },
    ];
    const out = median3Filter(input);
    expect(out.map((p) => p.x)).toEqual([100, 200, 300]);
  });
});
