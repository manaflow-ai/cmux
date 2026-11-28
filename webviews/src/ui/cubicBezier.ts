// A CSS cubic-bezier() easing as numbers: its four control values, the CSS text, and its value at a
// point (the same curve the browser draws for `cubic-bezier(x1, y1, x2, y2)`). Pure: tested without a DOM.

/** x1, y1, x2, y2: the two control points; the curve runs from (0, 0) to (1, 1). */
export type CubicBezier = readonly [number, number, number, number];

/** CSS accepts any y; the editor and the parser keep y in this range so a curve stays on screen. */
export const BEZIER_Y_RANGE = [-1, 2] as const;

const round = (value: number) => Math.round(value * 1000) / 1000;

export function cssBezier(curve: CubicBezier): string {
  return `cubic-bezier(${curve.map(round).join(", ")})`;
}

/** The URL form: `0.2,0.6,0.1,1`. */
export function formatBezier(curve: CubicBezier): string {
  return curve.map(round).join(",");
}

/** Four numbers split by commas or spaces, with or without `cubic-bezier( )`; x in 0...1. */
export function parseBezier(text: string): CubicBezier | undefined {
  const inner = text
    .trim()
    .replace(/^cubic-bezier\(\s*/i, "")
    .replace(/\s*\)$/, "");
  const parts = inner
    .split(/[\s,]+/)
    .filter(Boolean)
    .map(Number);
  if (parts.length !== 4 || !parts.every(Number.isFinite)) return undefined;
  const [x1, y1, x2, y2] = parts as [number, number, number, number];
  const [low, high] = BEZIER_Y_RANGE;
  if (x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1) return undefined;
  if ([y1, y2].some((y) => y < low || y > high)) return undefined;
  return [x1, y1, x2, y2];
}

export function sameBezier(a: CubicBezier, b: CubicBezier): boolean {
  return a.every((value, index) => round(value) === round(b[index]!));
}

/** One coordinate of the curve at parameter t, for control values p1 and p2. */
const coordinate = (t: number, p1: number, p2: number) =>
  3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3;
const slope = (t: number, p1: number, p2: number) =>
  3 * (1 - t) ** 2 * p1 + 6 * (1 - t) * t * (p2 - p1) + 3 * t ** 2 * (1 - p2);

/** The curve's y where its x is `x` (0...1): Newton steps, then bisection where the slope is flat. */
export function bezierAt(curve: CubicBezier, x: number): number {
  const [x1, y1, x2, y2] = curve;
  if (x <= 0) return 0;
  if (x >= 1) return 1;
  let t = x;
  for (let i = 0; i < 8; i++) {
    const error = coordinate(t, x1, x2) - x;
    if (Math.abs(error) < 1e-6) return coordinate(t, y1, y2);
    const d = slope(t, x1, x2);
    if (Math.abs(d) < 1e-6) break;
    t -= error / d;
  }
  let low = 0;
  let high = 1;
  t = x;
  for (let i = 0; i < 40; i++) {
    const value = coordinate(t, x1, x2);
    if (Math.abs(value - x) < 1e-6) break;
    if (value < x) low = t;
    else high = t;
    t = (low + high) / 2;
  }
  return coordinate(t, y1, y2);
}
