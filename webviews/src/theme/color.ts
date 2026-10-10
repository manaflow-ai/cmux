// Color math for the app theme (appTheme.ts): sRGB hex in and out, WCAG 2 relative luminance and
// contrast, and OKLCH (Björn Ottosson's OKLab in polar form) to move a color's lightness while its
// hue stays the same. Pure functions with no DOM, so a Swift or Rust port can replay them.

/** An opaque sRGB color with channels in 0...1. */
export type RGB = { r: number; g: number; b: number };

/** OKLCH: lightness 0...1, chroma 0...~0.37, hue in degrees 0...360. */
export type OKLCH = { l: number; c: number; h: number };

const clamp01 = (value: number) => Math.min(Math.max(value, 0), 1);

/** `#rgb`, `#rrggbb` or `#rrggbbaa` (alpha ignored; the `#` optional); null when malformed. */
export function parseHex(text: string): RGB | null {
  let digits = text.trim().replace(/^#/, "");
  if (digits.length === 3)
    digits = digits
      .split("")
      .map((digit) => digit + digit)
      .join("");
  if (digits.length === 8) digits = digits.slice(0, 6);
  if (!/^[0-9a-fA-F]{6}$/.test(digits)) return null;
  const value = parseInt(digits, 16);
  return { r: ((value >> 16) & 0xff) / 255, g: ((value >> 8) & 0xff) / 255, b: (value & 0xff) / 255 };
}

/** `#rrggbb`, each channel rounded to 8 bits. */
export function toHex(color: RGB): string {
  const channel = (value: number) =>
    Math.round(clamp01(value) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${channel(color.r)}${channel(color.g)}${channel(color.b)}`;
}

/** The color as its 8-bit hex rounds it, so a contrast check sees what a screen shows. */
export const quantized = (color: RGB): RGB => parseHex(toHex(color))!;

const toLinear = (c: number) => (c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
const fromLinear = (c: number) => (c <= 0.0031308 ? c * 12.92 : 1.055 * Math.pow(c, 1 / 2.4) - 0.055);

/** WCAG 2 relative luminance. */
export function luminance(color: RGB): number {
  return 0.2126 * toLinear(color.r) + 0.7152 * toLinear(color.g) + 0.0722 * toLinear(color.b);
}

/** WCAG 2 contrast ratio, 1...21. */
export function contrast(a: RGB, b: RGB): number {
  const x = luminance(a);
  const y = luminance(b);
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
}

/** Linear-light mix in sRGB space: `fraction` 0 is `a`, 1 is `b`. */
export function mix(a: RGB, b: RGB, fraction: number): RGB {
  const t = clamp01(fraction);
  return { r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t };
}

export const WHITE: RGB = { r: 1, g: 1, b: 1 };
export const BLACK: RGB = { r: 0, g: 0, b: 0 };

/** Unclamped linear sRGB of an OKLCH color (out-of-gamut channels fall outside 0...1). */
function oklchToLinear({ l, c, h }: OKLCH): [number, number, number] {
  const radians = (h * Math.PI) / 180;
  const a = c * Math.cos(radians);
  const b = c * Math.sin(radians);
  const l_ = Math.pow(l + 0.3963377774 * a + 0.2158037573 * b, 3);
  const m_ = Math.pow(l - 0.1055613458 * a - 0.0638541728 * b, 3);
  const s_ = Math.pow(l - 0.0894841775 * a - 1.291485548 * b, 3);
  return [
    4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
    -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
    -0.0041960863 * l_ - 0.7034186147 * m_ + 1.707614701 * s_,
  ];
}

export function toOklch(color: RGB): OKLCH {
  const r = toLinear(color.r);
  const g = toLinear(color.g);
  const b = toLinear(color.b);
  const l = Math.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  const m = Math.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  const s = Math.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  const L = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s;
  const A = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s;
  const B = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s;
  const hue = (Math.atan2(B, A) * 180) / Math.PI;
  return { l: L, c: Math.hypot(A, B), h: hue < 0 ? hue + 360 : hue };
}

const inGamut = (channels: [number, number, number]) => channels.every((c) => c >= -1e-4 && c <= 1 + 1e-4);

/**
 * The sRGB color of an OKLCH value. Out of gamut, chroma drops (hue and lightness kept) until the
 * color fits, the CSS Color 4 approach without its perceptual tolerance.
 */
export function fromOklch(color: OKLCH): RGB {
  const l = clamp01(color.l);
  let low = 0;
  let high = Math.max(color.c, 0);
  if (!inGamut(oklchToLinear({ l, c: high, h: color.h }))) {
    for (let step = 0; step < 24; step += 1) {
      const middle = (low + high) / 2;
      if (inGamut(oklchToLinear({ l, c: middle, h: color.h }))) low = middle;
      else high = middle;
    }
    high = low;
  }
  const [r, g, b] = oklchToLinear({ l, c: high, h: color.h });
  return { r: clamp01(fromLinear(clamp01(r))), g: clamp01(fromLinear(clamp01(g))), b: clamp01(fromLinear(clamp01(b))) };
}

/** The smallest angle between two hues, in degrees. */
export function hueDistance(a: number, b: number): number {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
}
