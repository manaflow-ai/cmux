// l10n-allow-file: gallery fixtures, not shipped UI.
// The Settings motions that change the list's height on purpose, measured apart from
// pages.settings (whose layout-shift limit stays 0): search filtering collapses rows in place,
// a cleared scope override removes its line, and the states in settings.gallery's
// heightChangingVariants open or drop content above rows. Their layout shift is recorded, not gated at 0.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import { heightChangingVariants } from "./settings.gallery";

const variants: Record<string, SettingsPageVariant> = {
  ...heightChangingVariants,
  "play-search": {
    section: "general",
    note: "Typing a search: rows outside it collapse in place (height and opacity), nothing jumps.",
    play: async (ctx) => {
      await ctx.type("tab", { selector: "[data-settings-search]" });
      await ctx.waitFor(() => ctx.document.querySelector("[data-search-results]"));
      await ctx.type(" bar", { selector: "[data-settings-search]" });
      await ctx.press("Escape");
      await ctx.waitFor(() => ctx.document.querySelector("[data-section]:not(.result-section)"));
    },
  },
  "play-override-reset": {
    section: "theme",
    allThemes: true,
    note: "Reset on an inline scope override: the line goes away.",
    play: async (ctx) => {
      await ctx.click({ selector: '[data-override="workspace"] button' });
      await ctx.waitFor(() => !ctx.document.querySelector('[data-override="workspace"]'));
    },
  },
};

export default settingsPageEntry({
  id: "pages.settings-motion",
  title: "Settings motion",
  area: "Settings",
  height: 760,
  covers: ["page:cmux.settings", "pages/settings/components/SearchResults.tsx"],
  anchors: [{ selector: "[data-settings-search]" }, { selector: '[data-section-link="general"]' }],
  checks: {
    layoutShiftMax: {
      value: 1,
      reason:
        "These steps change the list's height on purpose (a filter, a removed override line); rows below move with it. The strict 0 limit stays on pages.settings.",
    },
  },
  variants,
});
