// The math behind the per-token theme editor (cx-wqn5): the contrast floor each token keeps, the
// colors it snaps to (its own theme's and the nearest of every other theme's), and the lift that
// brings a color back over its floor. Pure, so the page and its tests share it.
import { deriveAppTheme, fit } from "./appTheme";
import { contrast, fromOklch, parseHex, toHex, toOklch, type OKLCH, type RGB } from "./color";
import type { GhosttyTheme } from "./ghosttyTheme";
import type { ThemeEditToken } from "./themeEdits";

/** What a token is read against, and the WCAG contrast it should keep there; null: no floor. */
export type ContrastFloor = { against: "background" | "foreground"; min: number } | null;

/**
 * Text on the background (foreground, and the background under it) keeps 4.5:1 (WCAG AA); the
 * cursor, the selection and the ANSI colors keep 3:1, the non-text and large-text floor most
 * themes already meet. ANSI 0 (black) is often the background itself, so it has none.
 */
export function contrastFloor(token: ThemeEditToken): ContrastFloor {
  switch (token) {
    case "foreground":
      return { against: "background", min: 4.5 };
    case "background":
      return { against: "foreground", min: 4.5 };
    case "selection":
      return { against: "foreground", min: 3 };
    case "0":
      return null;
    default:
      return { against: "background", min: 3 };
  }
}

/** A token's color in `theme`, as the terminal draws it. */
export function tokenColor(theme: GhosttyTheme, token: ThemeEditToken): string {
  switch (token) {
    case "background":
      return theme.background;
    case "foreground":
      return theme.foreground;
    case "cursor":
      return theme.cursorColor ?? theme.foreground;
    case "selection":
      return theme.selectionBackground ?? toHex(mixRgb(theme.background, theme.foreground, 0.25));
    case "accent":
      // Without its own accent, the one the app derives for the theme (neutral by default).
      return theme.accent ?? deriveAppTheme(theme).tokens.accent;
    default:
      return theme.palette[Number(token)] ?? theme.foreground;
  }
}

function mixRgb(a: string, b: string, fraction: number): RGB {
  const x = parseHex(a)!;
  const y = parseHex(b)!;
  return { r: x.r + (y.r - x.r) * fraction, g: x.g + (y.g - x.g) * fraction, b: x.b + (y.b - x.b) * fraction };
}

/** The contrast `color` reaches against what `token` is read on in `theme`; null with no floor. */
export function tokenContrast(theme: GhosttyTheme, token: ThemeEditToken, color: string): number | null {
  const floor = contrastFloor(token);
  const rgb = parseHex(color);
  const against = floor && parseHex(floor.against === "background" ? theme.background : theme.foreground);
  return floor && rgb && against ? contrast(rgb, against) : null;
}

/** `color` lifted (lightness only, hue kept) until it meets `token`'s floor in `theme`; unchanged when it does. */
export function meetFloor(theme: GhosttyTheme, token: ThemeEditToken, color: string): string {
  const floor = contrastFloor(token);
  const rgb = parseHex(color);
  const against = floor && parseHex(floor.against === "background" ? theme.background : theme.foreground);
  if (!floor || !rgb || !against) return color;
  return toHex(fit(rgb, [{ on: against, min: floor.min }]));
}

/** OKLab distance: about 0.02 is a just-noticeable difference. */
export function colorDistance(a: string, b: string): number {
  const x = parseHex(a);
  const y = parseHex(b);
  if (!x || !y) return Infinity;
  const p = toOklch(x);
  const q = toOklch(y);
  const ab = (c: OKLCH) => [c.c * Math.cos((c.h * Math.PI) / 180), c.c * Math.sin((c.h * Math.PI) / 180)];
  const [pa, pb] = ab(p);
  const [qa, qb] = ab(q);
  return Math.hypot(p.l - q.l, pa! - qa!, pb! - qb!);
}

/**
 * The colors a token snaps to, nearest first: the theme's own (its other tokens), then the nearest
 * of every other theme's colors, no two closer than a just-noticeable step. At most `limit`.
 */
export function snapColors(
  theme: GhosttyTheme,
  token: ThemeEditToken,
  color: string,
  others: Iterable<GhosttyTheme>,
  limit = 10,
): string[] {
  const own = [theme.background, theme.foreground, ...theme.palette.filter((value): value is string => !!value)];
  const near = (list: string[]) => [...new Set(list.map((value) => value.toLowerCase()))];
  const pool: string[] = [];
  for (const other of others) {
    if (other.name === theme.name) continue;
    pool.push(other.background, other.foreground, ...other.palette.filter((value): value is string => !!value));
  }
  const current = tokenColor(theme, token).toLowerCase();
  const chosen: string[] = [];
  const add = (candidate: string) => {
    if (candidate === color.toLowerCase() || candidate === current) return;
    if (chosen.some((kept) => colorDistance(kept, candidate) < 0.02)) return;
    chosen.push(candidate);
  };
  near(own)
    .sort((a, b) => colorDistance(a, color) - colorDistance(b, color))
    .slice(0, Math.ceil(limit / 2))
    .forEach(add);
  near(pool)
    .sort((a, b) => colorDistance(a, color) - colorDistance(b, color))
    .forEach((candidate) => chosen.length < limit && add(candidate));
  return chosen.slice(0, limit);
}

/**
 * A slider's color pulled onto a snap color within `radius` (OKLab), as a magnet does; else itself.
 * Only a snap the slider moves toward from `from` pulls, so a step away from a snap leaves it.
 */
export function magnet(color: string, snaps: readonly string[], from?: string, radius = 0.025): string {
  let best: string | null = null;
  let distance = radius;
  for (const snap of snaps) {
    const d = colorDistance(color, snap);
    if (from !== undefined && d >= colorDistance(from, snap)) continue;
    if (d < distance) {
      best = snap;
      distance = d;
    }
  }
  return best ?? color;
}

/** `#rrggbb` from OKLCH channels (chroma reduced to stay in sRGB). */
export function hexFromOklch(lch: OKLCH): string {
  return toHex(fromOklch(lch));
}

/** OKLCH channels of `#rrggbb`. */
export function oklchFromHex(hex: string): OKLCH {
  return toOklch(parseHex(hex) ?? { r: 0, g: 0, b: 0 });
}
