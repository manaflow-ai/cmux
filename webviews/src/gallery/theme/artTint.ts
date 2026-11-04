// Glass tint that follows the art (design/theming.md step 5, "Glass candy"): the art's dominant colors
// and the darkest and lightest it gets, read once from a small copy of it, and a glass tint mixed from
// the theme surface toward the art's leading color at the least alpha that keeps every ink 4.5:1 over
// any part of the art. The theme surface itself always reads (WebTheme's guarantee), so there is always
// an answer: at worst the opaque surface. Pure: the gallery stage (GlassCandyStage.tsx) feeds it
// getImageData bytes; the wallpaper-palette step can port it as is.
import { cssRounded } from "./overlays";
import { composited, contrast, mixed, MINIMUM_TEXT_CONTRAST, rgb, withAlpha, type ThemeRGB } from "./tokens";

/** The art as the glass's blur sees it: its leading colors, and the per-channel floor and ceiling. */
export type ArtPalette = {
  /** The art's leading colors, most of it first; vivid colors weigh more than greys. */
  dominant: ThemeRGB[];
  /** Per channel, the least of any sample: no blurred pixel of the art is darker in any channel. */
  low: ThemeRGB;
  /** Per channel, the most of any sample. */
  high: ThemeRGB;
};

/** The width (and height) of the copy the stage reads: one sample per glass-blur-sized cell. */
export const PALETTE_SAMPLE = 64;
/** Bits kept per channel when bucketing colors. */
const BUCKET_BITS = 3;
/** Two leading colors closer than this (sRGB distance, 0 to ~1.7) count as one. */
const DISTINCT = 0.2;
/** The lowest alpha the art-following tint starts its search at: below it glass reads as a smear. */
export const ART_TINT_MINIMUM_ALPHA = 0.3;

/** HSV saturation of an opaque color, 0 to 1. */
function saturation(color: ThemeRGB): number {
  const high = Math.max(color.red, color.green, color.blue);
  const low = Math.min(color.red, color.green, color.blue);
  return high <= 0 ? 0 : (high - low) / high;
}

const distance = (a: ThemeRGB, b: ThemeRGB) => Math.hypot(a.red - b.red, a.green - b.green, a.blue - b.blue);

/** The palette of RGBA bytes (`ImageData.data`); transparent samples are skipped. */
export function artPalette(data: ArrayLike<number>, count = 3): ArtPalette {
  const levels = 1 << BUCKET_BITS;
  const buckets = new Map<number, { n: number; r: number; g: number; b: number }>();
  let low = [1, 1, 1];
  let high = [0, 0, 0];
  let seen = 0;
  for (let index = 0; index + 3 < data.length; index += 4) {
    if ((data[index + 3] ?? 0) < 128) continue;
    const channels = [data[index]!, data[index + 1]!, data[index + 2]!].map((value) => value / 255);
    low = low.map((value, c) => Math.min(value, channels[c]!));
    high = high.map((value, c) => Math.max(value, channels[c]!));
    const key = channels.reduce((sum, value) => sum * levels + Math.min(levels - 1, Math.floor(value * levels)), 0);
    const bucket = buckets.get(key) ?? { n: 0, r: 0, g: 0, b: 0 };
    bucket.n += 1;
    bucket.r += channels[0]!;
    bucket.g += channels[1]!;
    bucket.b += channels[2]!;
    buckets.set(key, bucket);
    seen += 1;
  }
  if (seen === 0) return { dominant: [], low: rgb(0, 0, 0), high: rgb(1, 1, 1) };
  const ranked = [...buckets.values()]
    .map(({ n, r, g, b }) => {
      const color = rgb(r / n, g / n, b / n);
      return { color, score: n * (0.35 + saturation(color)) };
    })
    .sort((a, b) => b.score - a.score);
  const dominant: ThemeRGB[] = [];
  for (const { color } of ranked) {
    if (dominant.length >= count) break;
    if (dominant.every((picked) => distance(picked, color) >= DISTINCT)) dominant.push(color);
  }
  return { dominant, low: rgb(low[0]!, low[1]!, low[2]!), high: rgb(high[0]!, high[1]!, high[2]!) };
}

export type ArtTintInput = {
  /** The theme's opaque surface (`--cmux-surface-solid`). */
  surface: ThemeRGB;
  /** Every ink drawn on the glass (`--cmux-text`, `--cmux-text-secondary`); alpha is honoured. */
  inks: readonly ThemeRGB[];
  palette: ArtPalette;
  /** The window's wash over the art (the backdrop's `tint`), if any. */
  wash?: ThemeRGB;
  /** How far the tint moves from the surface toward the art's leading color, 0 to 1. 0: neutral. */
  follow: number;
};

export type ArtTint = {
  /** The glass fill, with its alpha. */
  tint: ThemeRGB;
  /** The worst contrast of any ink on that fill over any part of the art. */
  worst: number;
  /** The follow that was kept (lowered from the asked one when the asked one cannot read). */
  follow: number;
};

/** Every ink's least contrast on `fill` laid over each extreme the backdrop can reach. */
export function worstOverArt(fill: ThemeRGB, inks: readonly ThemeRGB[], backdrops: readonly ThemeRGB[]): number {
  let worst = Number.POSITIVE_INFINITY;
  for (const backdrop of backdrops) {
    // As the page draws it: 8-bit channels, alpha to three places.
    const glass = composited(cssRounded(fill), backdrop);
    for (const ink of inks) {
      const drawn = ink.alpha < 1 ? composited(cssRounded(ink), glass) : cssRounded(ink);
      worst = Math.min(worst, contrast(drawn, glass));
    }
  }
  return worst;
}

/**
 * The art-following tint. The backdrop's extremes are the corners of its per-channel box (with the
 * wash laid over them): luminance and alpha compositing both rise with every channel, so no pixel of
 * the art, blurred or bent, lies outside them. The fill is the surface moved `follow` of the way
 * toward the art's leading color (less, if even the opaque fill would not read), at the least alpha
 * from ART_TINT_MINIMUM_ALPHA on that keeps every ink 4.5:1.
 */
export function artGlassTint({ surface, inks, palette, wash, follow }: ArtTintInput): ArtTint {
  const solid = withAlpha(surface, 1);
  const lead = palette.dominant[0];
  const corners = [palette.low, palette.high].map((corner) => (wash ? composited(wash, corner) : corner));
  let kept = lead ? Math.min(Math.max(follow, 0), 1) : 0;
  let fill = solid;
  for (; kept > 0; kept = Math.round((kept - 0.05) * 100) / 100) {
    fill = mixed(solid, lead!, kept);
    if (worstOverArt(fill, inks, corners) >= MINIMUM_TEXT_CONTRAST) break;
  }
  if (kept <= 0) {
    kept = 0;
    fill = solid;
  }
  for (let percent = Math.round(ART_TINT_MINIMUM_ALPHA * 100); percent < 100; percent += 1) {
    const tint = withAlpha(fill, percent / 100);
    const worst = worstOverArt(tint, inks, corners);
    if (worst >= MINIMUM_TEXT_CONTRAST) return { tint, worst, follow: kept };
  }
  return { tint: fill, worst: worstOverArt(fill, inks, corners), follow: kept };
}
