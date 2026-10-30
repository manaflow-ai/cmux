// A theme drawn as a ball: its background as the disc, its text color at the center, and its six
// ANSI hues (red, green, yellow, blue, magenta, cyan) in a ring, the hue the `theme` accent takes
// drawn largest. Light and dark, warm and cool, read at a glance. The geometry is in a 24-unit
// box, and every mark is a circle.
import { colorfulSlot, resolvedPalette, themeAccentSlot, type TerminalColors } from "./appTheme";
import { toHex } from "./color";

export type ThemeBallDot = { cx: number; cy: number; r: number; fill: string };
export type ThemeBall = {
  surface: ThemeBallDot;
  text: ThemeBallDot;
  /** Hues 1-6 in ANSI order, clockwise from the top. */
  ring: (ThemeBallDot & { hue: number; accent: boolean })[];
};

export const BALL_SIZE = 24;
const CENTER = BALL_SIZE / 2;
const SURFACE_R = 11.25;
const RING_R = 6.5;
const HUE_R = 2.1;
const ACCENT_R = 2.9;
const TEXT_R = 2.6;

const round = (value: number) => Math.round(value * 1000) / 1000;

export function themeBall(colors: TerminalColors): ThemeBall {
  const palette = resolvedPalette(colors);
  const accentSlot = themeAccentSlot(palette);
  const ring = [1, 2, 3, 4, 5, 6].map((hue, index) => {
    const slot = colorfulSlot(palette, hue);
    const angle = -Math.PI / 2 + (index * Math.PI) / 3;
    const accent = accentSlot !== null && accentSlot % 8 === hue;
    return {
      hue,
      accent,
      cx: round(CENTER + RING_R * Math.cos(angle)),
      cy: round(CENTER + RING_R * Math.sin(angle)),
      r: accent ? ACCENT_R : HUE_R,
      fill: colors.palette[slot] ?? toHex(palette[slot]!),
    };
  });
  return {
    surface: { cx: CENTER, cy: CENTER, r: SURFACE_R, fill: colors.background },
    text: { cx: CENTER, cy: CENTER, r: TEXT_R, fill: colors.foreground },
    ring,
  };
}
