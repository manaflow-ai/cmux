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
  height: 560,
  widths: { narrow: 420, normal: 640, wide: 820 },
  covers: [
    "page:cmux.icon-picker",
    "icon-picker/IconPicker.tsx",
    "icon-picker/AssetTab.tsx",
    "icon-picker/VirtualGrid.tsx",
    "icon-picker/JumpBar.tsx",
  ],
  variants: {
    "long-content": {
      session,
      note: "A long search query in the real search field.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-picker-search"));
        await ctx.type("face with a very long descriptive search query that exceeds the search field", {
          selector: ".icon-picker-search",
        });
      },
    },
    loading: { session: { ...session, tab: "image" }, assetState: "loading", play: assetPlay(false) },
    error: { session: { ...session, tab: "image" }, assetState: "error", play: assetPlay(true) },
    emoji: { note: "Emoji search with a focused field and selected cell.", session, active: 12 },
    symbols: { note: "The SF Symbols tab with a selected symbol.", session: { ...session, tab: "symbol" }, active: 8 },
    image: { note: "The image asset sheet with paste, file and URL actions.", session: { ...session, tab: "image" } },
    svg: { note: "The SVG asset sheet.", session: { ...session, tab: "svg" } },
    empty: { note: "A search with no matching icons.", mode: "empty", session },
    "no-clear": { note: "A picker session without a remove action.", session: { ...session, canClear: false } },
  },
});
