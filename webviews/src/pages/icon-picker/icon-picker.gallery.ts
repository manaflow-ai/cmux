// l10n-allow-file: gallery fixtures (public-safe icon picker sessions), not shipped UI.
import { iconPickerPageEntry, type IconPickerPageVariant } from "../../gallery/format";

const symbols = [
  "star",
  "star.fill",
  "heart",
  "heart.fill",
  "folder",
  "folder.fill",
  "terminal",
  "terminal.fill",
  "globe",
  "house",
  "gearshape",
  "bolt",
  "flame",
  "leaf",
  "hammer",
  "wrench.and.screwdriver",
  "person.crop.circle",
  "bubble.left.and.bubble.right",
  "cloud",
  "server.rack",
] as const;

const session = { id: "gallery-session", tab: "emoji", canClear: true, assets: true, symbols } as const;

/** Saved prefs with recent picks, so the grid opens on Frequently Used (emoji and symbols). */
const recent = ["😎", "🎉", "🐮", "🎈", "🥲", "🍑", "🤨", "🫡", "💜", "🩸", "🙏", "🤔", "🤦"];
const prefs = {
  tone: 0,
  recents: [
    ...recent.map((emoji, rank) => ({ key: `emoji:${emoji}`, count: 40 - rank * 2, last: Date.parse("2026-10-08") })),
    { key: "symbol:terminal", count: 6, last: Date.parse("2026-10-08") },
    { key: "symbol:folder.fill", count: 5, last: Date.parse("2026-10-08") },
    { key: "symbol:bolt", count: 4, last: Date.parse("2026-10-08") },
  ],
};

const assetPlay =
  (failed: boolean): IconPickerPageVariant["play"] =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".icon-asset-url input"));
    await ctx.type("https://example.org/sample-icon.png", { selector: ".icon-asset-url input" });
    await ctx.click({ selector: ".icon-asset-url button" });
    await ctx.waitFor(() =>
      ctx.document.querySelector(failed ? ".icon-asset-error" : ".icon-asset-url button:disabled"),
    );
  };

export default iconPickerPageEntry({
  id: "pages.icon-picker",
  title: "Icon picker",
  area: "Pages",
  height: 520,
  widths: { narrow: 440, normal: 600, wide: 760 },
  covers: [
    "page:cmux.icon-picker",
    "icon-picker/IconPicker.tsx",
    "icon-picker/AssetTab.tsx",
    "icon-picker/VirtualGrid.tsx",
  ],
  variants: {
    emoji: {
      note: "All Categories: Frequently Used (emoji and symbols), then the emoji groups, with the first tile selected.",
      session,
      prefs,
    },
    "long-content": {
      session,
      prefs,
      note: "A long search query in the real search field.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-picker-search"));
        await ctx.type("face with a very long descriptive search query that exceeds the search field", {
          selector: ".icon-picker-search",
        });
      },
    },
    search: { note: "A search over emoji and SF Symbols in one grid.", session, prefs, query: "star" },
    symbols: {
      note: "The SF Symbols category with a selected symbol.",
      session: { ...session, tab: "symbol" },
      active: 8,
    },
    categories: {
      note: "The All Categories menu open, with counts.",
      session,
      prefs,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-category-button"));
        await ctx.click({ selector: ".icon-category-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".icon-category-menu"));
      },
    },
    actions: {
      note: "The Actions menu (Cmd-K) over the bottom bar.",
      session,
      prefs,
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-picker-search"));
        await ctx.press("Meta+k");
        await ctx.waitFor(() => ctx.document.querySelector(".icon-actions-menu"));
      },
    },
    loading: { session: { ...session, tab: "image" }, assetState: "loading", play: assetPlay(false) },
    error: { session: { ...session, tab: "image" }, assetState: "error", play: assetPlay(true) },
    image: { note: "The image sheet with paste, file and URL actions.", session: { ...session, tab: "image" } },
    svg: { note: "The SVG sheet.", session: { ...session, tab: "svg" } },
    empty: { note: "A search with no matching icons.", mode: "empty", session },
    "no-clear": { note: "A picker session without a remove action.", session: { ...session, canClear: false } },
  },
});
