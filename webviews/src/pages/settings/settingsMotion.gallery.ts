// l10n-allow-file: gallery fixtures, not shipped UI.
// The Settings motions that change the list's height on purpose, measured apart from
// pages.settings (whose layout-shift limit stays 0): search filtering collapses rows in place,
// a list setting's Reset removes its items, and a cleared scope override removes its line.
import { settingsPageEntry, type SettingsPageVariant } from "../../gallery/format";
import { homes } from "./categories";

const row = (key: string) => `[data-row-key="${key}"]`;
const customized: Record<string, unknown> = {
  "browser.hibernationExclusions": ["docs.example.test", "*.research.example.test"],
  "picker.pinned": ["~/Projects/Atlas", "~/Projects/Research"],
  "sidebar.workspaceRow.secondLineOrder": ["branch", "directory"],
};
const variants: Record<string, SettingsPageVariant> = {
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
  "play-changed-only": {
    section: "general",
    options: { values: customized },
    note: "Show Only Changed: the list narrows to changed rows in place.",
    play: async (ctx) => {
      await ctx.click({ selector: "[data-changed-only]" });
      await ctx.waitFor(() => ctx.document.querySelector("[data-search-results]"));
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
for (const key of Object.keys(customized))
  variants[`play-reset-${key.split(".").at(-1)!.toLowerCase()}`] = {
    section: homes.get(key)!.category,
    focus: key,
    options: { values: customized },
    note: `Reset on a list row (${key}): its items go away; the Reset slot itself does not move.`,
    play: async (ctx) => {
      await ctx.click({ selector: `${row(key)} [data-reset]` });
      await ctx.waitFor(() => !ctx.document.querySelector(`${row(key)} [data-reset]`));
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
      value: 0.25,
      reason:
        "These steps change the list's height on purpose (a filter, removed list items, a removed override line); rows below move with it. The strict 0 limit stays on pages.settings.",
    },
  },
  variants,
});
