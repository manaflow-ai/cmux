// l10n-allow-file: gallery prototype fixtures, not shipped UI.
// Settings navigation, pushed harder (findings G6, 2026-11-22; Beyer 2026-11-20: Settings felt
// "overwhelming"). Three opt-in layouts over the real settings registry; the shipped page
// (`pages.settings`) is unchanged. Compare with its `appearance` variant: 17 pages plus "More 12".
import { componentEntry } from "../../gallery/format";
import type { SettingsIAProps } from "./SettingsIA";

export default componentEntry<SettingsIAProps>({
  id: "settings.navigation-prototypes",
  title: "Settings navigation: three ways",
  area: "Settings",
  experimental: true,
  keywords: [
    "settings",
    "navigation",
    "ia",
    "beyer",
    "overwhelming",
    "search",
    "palette",
    "six pages",
    "progressive disclosure",
  ],
  covers: ["prototypes/settings-ia/SettingsIA.tsx", "prototypes/settings-ia/model.ts"],
  load: () => import("./SettingsIA").then((module) => module.SettingsIA),
  height: 820,
  widths: { narrow: 720, normal: 1100, wide: 1400 },
  variants: {
    "search-first": {
      note: "(a) One page: search is the way in, six jump chips, then every setting in one scroll.",
      props: { layout: "search-first" },
    },
    "search-first-query": {
      note: '(a) Typing "font size" lists every match across pages, with where it lives.',
      props: { layout: "search-first", query: "font size" },
    },
    "six-pages": {
      note: "(b) Six pages; each shows its first groups, the rest one click away.",
      props: { layout: "six-pages", page: "appearance" },
    },
    "six-pages-advanced": {
      note: "(b) Advanced holds Terminal, Code Editor and Browser as folds; Terminal open.",
      props: { layout: "six-pages", page: "advanced", open: ["terminal"] },
    },
    palette: {
      note: "(c) Settings is a palette (⌘,): suggestions and the six pages, a live detail on the right.",
      props: { layout: "palette" },
    },
    "palette-query": {
      note: '(c) "font size" in the palette: results with their page, the value inline.',
      props: { layout: "palette", query: "font size" },
    },
  },
});
