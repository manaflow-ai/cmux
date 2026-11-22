// The overlay materials the app hands pages beside the theme tokens (WebTheme.swift's
// `--cmux-popup-surface`, `--cmux-tooltip-*`, `--cmux-card-*` and `--cmux-scrim`): ports of
// TooltipSurface.swift, CardMaterial.swift and Overlay/Scrim.swift. Without them a gallery stage drew
// menus, tooltips, cards and dialog scrims in each stylesheet's fallback, not in the app's material.
import {
  BLACK,
  composited,
  contrast,
  luminance,
  MINIMUM_TEXT_CONTRAST,
  mixed,
  opaqueOverlayFill,
  rgb,
  WHITE,
  withAlpha,
  type ThemeRGB,
  type ThemeTokens,
} from "./tokens";

/** ChromeTunables.opaqueOverlayLift's default. */
export const OPAQUE_OVERLAY_LIFT = 0.14;
/** CardMaterial.defaultMinimumOpacity (`glass.cardOpacity`). */
export const CARD_MINIMUM_OPACITY = 0.9;
/** TooltipSurface.minimumTintAlpha / maximumTintAlpha. */
const TOOLTIP_MINIMUM_TINT = 0.6;
const TOOLTIP_MAXIMUM_TINT = 0.9;

/** WebTheme.cssRounded: the color as a page reads it (8-bit channels, alpha to 3 decimals). */
export function cssRounded(color: ThemeRGB): ThemeRGB {
  const channel = (value: number) => Math.round(value * 255) / 255;
  return rgb(channel(color.red), channel(color.green), channel(color.blue), Math.round(color.alpha * 1000) / 1000);
}

/** TooltipSurface.worstContrast: `ink` over `tint` laid on pure black and on pure white. */
export function worstContrast(ink: ThemeRGB, tint: ThemeRGB): number {
  return Math.min(contrast(ink, composited(tint, BLACK)), contrast(ink, composited(tint, WHITE)));
}

function tintAlpha(fill: ThemeRGB, ink: ThemeRGB): number | null {
  const pageInk = cssRounded(ink);
  for (let percent = TOOLTIP_MINIMUM_TINT * 100; percent <= TOOLTIP_MAXIMUM_TINT * 100; percent += 1) {
    const tint = withAlpha(fill, percent / 100);
    if (Math.min(worstContrast(ink, tint), worstContrast(pageInk, cssRounded(tint))) >= MINIMUM_TEXT_CONTRAST)
      return percent / 100;
  }
  return null;
}

const reads = (ink: ThemeRGB, fill: ThemeRGB) =>
  Math.min(contrast(ink, fill), contrast(cssRounded(ink), cssRounded(fill))) >= MINIMUM_TEXT_CONTRAST;

/** TooltipSurface.legible: an ink that reads on the opaque fill, and the least translucent tint it
 * reads over on any backdrop (the ink walked toward its pole, then the tint away from it). */
export function tooltipSurface(tokens: ThemeTokens, lift = OPAQUE_OVERLAY_LIFT): { ink: ThemeRGB; tint: ThemeRGB } {
  const fill = withAlpha(opaqueOverlayFill(tokens, lift), 1);
  const ink = withAlpha(tokens.textPrimary, 1);
  const lightInk = luminance(ink) >= luminance(fill);
  const away = lightInk ? BLACK : WHITE;
  const inkPole = lightInk ? WHITE : BLACK;
  let opaque: ThemeRGB | null = null;
  for (let step = 0; step <= 100 && !opaque; step += 1) {
    const candidate = mixed(ink, inkPole, step / 100);
    if (reads(candidate, fill)) opaque = candidate;
  }
  if (opaque) {
    for (let step = 0; step <= 100; step += 1) {
      const color = mixed(fill, away, step / 100);
      const alpha = tintAlpha(color, opaque);
      if (alpha !== null) return { ink: opaque, tint: withAlpha(color, alpha) };
    }
    for (let step = 1; step <= 100; step += 1) {
      const moved = mixed(opaque, inkPole, step / 100);
      const alpha = tintAlpha(away, moved);
      if (alpha !== null) return { ink: moved, tint: withAlpha(away, alpha) };
    }
  }
  const pole = contrast(WHITE, fill) >= contrast(BLACK, fill) ? WHITE : BLACK;
  const under = pole === WHITE ? BLACK : WHITE;
  return { ink: pole, tint: withAlpha(under, tintAlpha(under, pole) ?? TOOLTIP_MINIMUM_TINT) };
}

/** CardMaterial(tokens, lift:, minimumOpacity:): the popup surface at the least alpha that keeps the
 * primary and secondary text 4.5:1 over any backdrop, and its rim. */
export function cardMaterial(
  tokens: ThemeTokens,
  lift = OPAQUE_OVERLAY_LIFT,
  minimumOpacity = CARD_MINIMUM_OPACITY,
): { tint: ThemeRGB; rim: ThemeRGB } {
  const fill = withAlpha(opaqueOverlayFill(tokens, lift), 1);
  const inks = [tokens.textPrimary, tokens.textSecondary].map((ink) => withAlpha(ink, 1));
  let opacity = 1;
  for (let percent = Math.round(Math.min(Math.max(minimumOpacity, 0), 1) * 100); percent < 100; percent += 1) {
    const tint = withAlpha(fill, percent / 100);
    if (inks.every((ink) => worstContrast(ink, tint) >= MINIMUM_TEXT_CONTRAST)) {
      opacity = percent / 100;
      break;
    }
  }
  return { tint: withAlpha(fill, opacity), rim: withAlpha(inks[0]!, tokens.isDark ? 0.18 : 0.14) };
}

/** ThemeTokens.scrim (Overlay/Scrim.swift): the modal dim, denser on a dark theme. */
export const scrim = (tokens: ThemeTokens): ThemeRGB => rgb(0, 0, 0, tokens.isDark ? 0.25 : 0.12);
