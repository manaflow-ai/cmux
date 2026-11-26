// The theme tokens a customization page, plugin or web page styles with: typed names for the one
// generated token list (ui/designTokens.generated.ts, from schemas/design-scale, type-scale and
// motion-scale), each as the var() its value lives in. Colors follow the active theme because the
// host derives the `--cmux-*` variables they read from it; nothing here holds a value of its own.
import { COLORS, CONTROLS, ICONS, MOTION, RADII, SPACING, TEXT } from "../ui/designTokens.generated";

export {
  COLORS,
  CONTROLS,
  EASE_STANDARD,
  ELEVATION,
  ICONS,
  MOTION,
  RADII,
  SPACING,
  TEXT,
} from "../ui/designTokens.generated";

export type ColorRole = (typeof COLORS)[number]["name"];
export type SpaceStep = (typeof SPACING)[number]["name"];
export type ControlHeight = (typeof CONTROLS)[number]["name"];
export type IconSize = (typeof ICONS)[number]["name"];
export type RadiusName = (typeof RADII)[number]["name"];
export type TextStep = (typeof TEXT)[number]["name"];
export type MotionStep = (typeof MOTION)[number]["name"];

const ref = (variable: string) => `var(${variable})`;

/** A color role (`fg`, `muted`, `accent`, `danger`...) as `var(--ds-color-*)`. */
export const color = (role: ColorRole) => ref(`--ds-color-${role}`);
/** A spacing step (`"1"` 4 px ... `"6"` 32 px, and the layout gaps) as `var(--ds-space-*)`. */
export const space = (step: SpaceStep) => ref(`--ds-space-${step}`);
/** A control height (`compact` 24, `row` 28, `primary` 32, `icon` 20). */
export const control = (name: ControlHeight) => ref(`--ds-control-${name}`);
/** An icon box (12, 14, 16, 20). */
export const icon = (size: IconSize) => ref(`--ds-icon-${size}`);
/** A corner radius (`sm`, `md`, `lg`, `xl`, or the named `control`, `popup`, `menu`, `card`). */
export const radius = (name: RadiusName) => ref(`--ds-radius-${name}`);
/** A type step's size; its line height is `textLineHeight`. */
export const text = (step: TextStep) => ref(`--text-${step}`);
export const textLineHeight = (step: TextStep) => ref(`--text-${step}--line-height`);
/** A motion duration; pair it with `EASE_STANDARD`. Reduce Motion is the host's to apply. */
export const motion = (step: MotionStep) => ref(`--cmux-motion-${step}`);

/** The layout grid's lengths that follow the interface scale (schemas/layout-grid, pages/shared/desktop.css
 * `--grid-*`), where the `--ds-space-*` steps are fixed px: base 4, half-step 2 (unscaled), gap 8,
 * glyph 12, icon-box 16 (comfortable 20), pill 24 (comfortable 28) and its 2 inset, row 28
 * (comfortable 32), all at scale 1. Names only: each is the app's own variable, no value of its own. */
export const GRID = [
  "base",
  "half-step",
  "gap",
  "glyph",
  "icon-box",
  "icon-box-comfortable",
  "pill",
  "pill-comfortable",
  "pill-inset",
  "row",
  "row-comfortable",
] as const;
export type GridLength = (typeof GRID)[number];
/** A layout grid length (`"base"`, `"gap"`, `"row"`, `"icon-box"`...) as `var(--grid-*)`. */
export const grid = (name: GridLength) => ref(`--grid-${name}`);
