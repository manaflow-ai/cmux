// l10n-allow-file: gallery fixtures, public-safe chrome and sample workspace labels.
import { componentEntry } from "../format";
import {
  WindowChromeShape,
  type ChromeDensity,
  type ChromeShapeVariant,
  type ChromeTheme,
  type WindowChromeShapeProps,
} from "./WindowChromeShape";
import { GOLDEN_LOOKS, type GoldenLookId } from "./goldenChromeLooks";
import type { GoldenChromeProps } from "./GoldenChrome";

type Props = {
  variant: ChromeShapeVariant;
  density: ChromeDensity;
  theme: ChromeTheme;
  menuScene?: WindowChromeShapeProps["menuScene"];
};

const variants: Record<string, Props & { note: string }> = {};
for (const variant of ["recommendation", "group-line", "aside-labels", "rex-icons"] as const)
  for (const density of ["compact", "comfortable"] as const)
    for (const theme of ["light", "dark"] as const) {
      const name = `${variant}-${density}-${theme}`;
      variants[name] = {
        variant,
        density,
        theme,
        note: `${variant} · ${density} · ${theme}; browser companion beside flat and strip agent tabs`,
      };
    }

for (const menuScene of [
  "one-zen",
  "one-zen-hover",
  "one-visible",
  "three-zen",
  "one-always-strip",
  "one-title-menu",
  "three-pane-menu",
  "three-developer-menu",
] as const)
  for (const density of ["compact", "comfortable"] as const)
    for (const theme of ["light", "dark"] as const) {
      variants[`recommendation-${density}-${theme}-${menuScene}`] = {
        variant: "recommendation",
        density,
        theme,
        menuScene,
        note: `header scene ${menuScene}; shared agent/browser pane header and reserved action slots`,
      };
    }

// The golden preview: the whole chrome (sidebar, tab strips, vertical tabs, top right buttons, Session Info,
// Home cards) from one look. `golden-<area>-<option>` varies one area; `golden-look-<name>` is a whole window.
// Each look is a theme file fragment (goldenChromeLooks.ts); light and dark follow the gallery's scheme.
const golden = Object.fromEntries(
  (Object.keys(GOLDEN_LOOKS) as GoldenLookId[]).map((id) => [
    `golden-${id}`,
    { props: { golden: id }, note: `golden preview · ${GOLDEN_LOOKS[id].label}: ${GOLDEN_LOOKS[id].note}` },
  ]),
);

export default componentEntry<Props | GoldenChromeProps>({
  id: "native.window-chrome-shapes",
  title: "Window chrome shape review",
  area: "Native",
  height: 860,
  widths: { narrow: 1080, normal: 1360, wide: 1680 },
  // A review of the native window and pane chrome shapes (radii, header seam), drawn as a fixture, and the
  // golden preview of every chrome shape at once.
  covers: ["swift:PaneChromeMetrics"],
  load: async () => WindowChromeShape,
  styles: () =>
    Promise.all([import("./WindowChromeShape.css"), import("./sidebarShapes.css"), import("./GoldenChrome.css")]),
  variants: {
    ...golden,
    ...Object.fromEntries(
      Object.entries(variants).map(([name, fixture]) => [name, { props: fixture, note: fixture.note }]),
    ),
  },
});
