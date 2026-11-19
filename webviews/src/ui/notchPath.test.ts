import { describe, expect, test } from "bun:test";
import { clampNotchOffset, NOTCH_HEIGHT, NOTCH_WIDTH, notchEdgeForSide, notchOutlinePath } from "./notchPath";

/** Every x y pair the path names, in order. */
function points(path: string): [number, number][] {
  const numbers = path
    .replace(/A [\d.]+ [\d.]+ 0 0 1/g, "")
    .replace(/[MLCZ]/g, " ")
    .trim()
    .split(/\s+/)
    .map(Number);
  const out: [number, number][] = [];
  for (let i = 0; i + 1 < numbers.length; i += 2) out.push([numbers[i]!, numbers[i + 1]!]);
  return out;
}

describe("notchOutlinePath", () => {
  test("is one closed path that starts and ends at the same point", () => {
    const path = notchOutlinePath(240, 120, 12, "top", 120);
    expect(path.startsWith("M 12 0")).toBe(true);
    expect(path.endsWith("Z")).toBe(true);
    expect(path.match(/M/g)?.length).toBe(1);
    const all = points(path);
    // The last arc lands back on the start.
    expect(all.at(-1)).toEqual(all[0]!);
  });

  test("puts the tip at the offset, outside the notched edge", () => {
    expect(points(notchOutlinePath(240, 120, 12, "top", 80))).toContainEqual([80, -NOTCH_HEIGHT]);
    expect(points(notchOutlinePath(240, 120, 12, "bottom", 80))).toContainEqual([80, 120 + NOTCH_HEIGHT]);
    expect(points(notchOutlinePath(240, 120, 12, "left", 50))).toContainEqual([-NOTCH_HEIGHT, 50]);
    expect(points(notchOutlinePath(240, 120, 12, "right", 50))).toContainEqual([240 + NOTCH_HEIGHT, 50]);
  });

  test("keeps the tip on the straight part of the edge, clear of the corners", () => {
    const min = 12 + NOTCH_WIDTH / 2;
    expect(points(notchOutlinePath(240, 120, 12, "top", -40))).toContainEqual([min, -NOTCH_HEIGHT]);
    expect(points(notchOutlinePath(240, 120, 12, "top", 999))).toContainEqual([240 - min, -NOTCH_HEIGHT]);
    expect(clampNotchOffset(30, 12, 3)).toBe(15);
  });

  test("pad moves the outline into a layer that starts outside the panel", () => {
    const path = notchOutlinePath(240, 120, 12, "top", 120, NOTCH_WIDTH, NOTCH_HEIGHT, NOTCH_HEIGHT);
    expect(path.startsWith(`M ${12 + NOTCH_HEIGHT} ${NOTCH_HEIGHT}`)).toBe(true);
    expect(points(path)).toContainEqual([120 + NOTCH_HEIGHT, 0]);
  });

  test("names the edge that faces the anchor", () => {
    expect(notchEdgeForSide("bottom")).toBe("top");
    expect(notchEdgeForSide("top")).toBe("bottom");
    expect(notchEdgeForSide("inline-end")).toBe("left");
    expect(notchEdgeForSide("inline-end", true)).toBe("right");
    expect(notchEdgeForSide(null)).toBeUndefined();
  });
});
