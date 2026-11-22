// Syntax colors for the diff viewer's Shiki theme, taken from the terminal's ANSI palette the
// host sends (`appearance.themes.{light,dark}.palette`, Ghostty `palette = N=#rrggbb`).

/// Ghostty's default palette (Apple System Colors), the same one the host falls back to. Used
/// for any slot the host leaves out, so a page without a palette still highlights.
export const defaultSyntaxPalettes: Record<"light" | "dark", Record<string, string>> = {
  light: {
    "0": "#1a1a1a",
    "1": "#cc372e",
    "2": "#26a439",
    "3": "#cdac08",
    "4": "#0869cb",
    "5": "#9647bf",
    "6": "#479ec2",
    "7": "#98989d",
    "8": "#464646",
    "9": "#ff453a",
    "10": "#32d74b",
    "11": "#e5bc00",
    "12": "#0a84ff",
    "13": "#bf5af2",
    "14": "#69c9f2",
    "15": "#ffffff",
  },
  dark: {
    "0": "#1a1a1a",
    "1": "#cc372e",
    "2": "#26a439",
    "3": "#cdac08",
    "4": "#0869cb",
    "5": "#9647bf",
    "6": "#479ec2",
    "7": "#98989d",
    "8": "#464646",
    "9": "#ff453a",
    "10": "#32d74b",
    "11": "#ffd60a",
    "12": "#0a84ff",
    "13": "#bf5af2",
    "14": "#76d6ff",
    "15": "#ffffff",
  },
};

/// Minimum contrast of a token against the background. Below WCAG's 4.5 for body text on
/// purpose: terminal palettes sit around 3 to 5, and raising every hue to 4.5 washes them out.
export const SYNTAX_MIN_CONTRAST = 3;

/// The color for the first palette slot that has one (host palette, then the default palette),
/// blended toward `foreground` just enough to reach `minimumContrast` against `background`.
export function syntaxPaletteColor(
  palette: Record<string, string | undefined>,
  slots: readonly number[],
  type: "light" | "dark",
  background: string,
  foreground: string,
  minimumContrast = SYNTAX_MIN_CONTRAST,
): string {
  const hostColor = slots.map((slot) => palette[String(slot)]).find(isColorString);
  const color = hostColor ?? slots.map((slot) => defaultSyntaxPalettes[type][String(slot)]).find(isColorString);
  return color == null ? foreground : withMinimumContrast(color, background, foreground, minimumContrast);
}

/// `color` unchanged when it reaches `minimumContrast` on `background`; otherwise the least
/// blend toward `toward` that does (the hue survives, unlike snapping to black or white).
export function withMinimumContrast(
  color: string,
  background: string,
  toward: string,
  minimumContrast: number,
): string {
  const rgb = parseHex(color);
  const bg = parseHex(background);
  const target = parseHex(toward);
  if (rgb == null || bg == null || target == null) return color.trim();
  if (contrast(rgb, bg) >= minimumContrast) return toHex(rgb);
  for (let step = 1; step <= 20; step++) {
    const mixed = mix(rgb, target, step / 20);
    if (contrast(mixed, bg) >= minimumContrast) return toHex(mixed);
  }
  return toHex(target);
}

export function contrastBetween(a: string, b: string): number | null {
  const left = parseHex(a);
  const right = parseHex(b);
  return left == null || right == null ? null : contrast(left, right);
}

type RGB = [number, number, number];

function isColorString(value: unknown): value is string {
  return typeof value === "string" && value.trim() !== "";
}

function parseHex(value: string): RGB | null {
  const hex = value.trim().replace(/^#/, "");
  if (/^[0-9a-f]{3}$/i.test(hex)) return [0, 1, 2].map((i) => Number.parseInt(hex[i] + hex[i], 16)) as RGB;
  if (/^[0-9a-f]{6}([0-9a-f]{2})?$/i.test(hex)) {
    return [0, 2, 4].map((i) => Number.parseInt(hex.slice(i, i + 2), 16)) as RGB;
  }
  return null;
}

function toHex(rgb: RGB): string {
  return `#${rgb.map((channel) => Math.round(channel).toString(16).padStart(2, "0")).join("")}`;
}

function mix(from: RGB, to: RGB, amount: number): RGB {
  return from.map((channel, index) => channel + (to[index] - channel) * amount) as RGB;
}

function contrast(a: RGB, b: RGB): number {
  const [lighter, darker] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (lighter + 0.05) / (darker + 0.05);
}

function luminance([red, green, blue]: RGB): number {
  const channel = (value: number) => {
    const normalized = value / 255;
    return normalized <= 0.03928 ? normalized / 12.92 : ((normalized + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue);
}
