// l10n-allow-file: gallery fixtures, public-safe chrome and sample workspace labels.
import { componentEntry } from "../format";
import {
  WindowChromeShape,
  type ChromeDensity,
  type ChromeShapeVariant,
  type ChromeTheme,
  type WindowChromeShapeProps,
} from "./WindowChromeShape";

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

export default componentEntry<Props>({
  id: "native.window-chrome-shapes",
  title: "Window chrome shape review",
  area: "Native",
  height: 860,
  widths: { narrow: 1080, normal: 1360, wide: 1680 },
  covers: ["gallery/fixtures/WindowChromeShape.tsx#WindowChromeShape"],
  load: async () => WindowChromeShape,
  styles: () => Promise.all([import("./WindowChromeShape.css"), import("./sidebarShapes.css")]),
  variants: Object.fromEntries(
    Object.entries(variants).map(([name, fixture]) => [name, { props: fixture, note: fixture.note }]),
  ),
});
