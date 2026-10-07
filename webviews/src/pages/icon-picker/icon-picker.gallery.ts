// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { PickerSession } from "./host";
function fixture(tab: PickerSession["tab"] = "emoji"): BridgePageVariant {
  const session: PickerSession = { id: "gallery-picker", tab, assets: true, canClear: true, symbols: [] };
  return {
    initialEvents: { "cmux.iconPicker.session": session },
    replies: {
      "cmux.iconPicker.prefs.load": null,
      "cmux.iconPicker.prefs.save": null,
      "cmux.iconPicker.finish": null,
    },
  };
}
const assetPlay =
  (failed: boolean): BridgePageVariant["play"] =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelector(".icon-asset-url input"));
    await ctx.type("https://example.org/sample-icon.png", { selector: ".icon-asset-url input" });
    await ctx.click({ selector: ".icon-asset-url button" });
    await ctx.waitFor(() =>
      ctx.document.querySelector(failed ? ".icon-asset-error" : ".icon-asset-url button:disabled"),
    );
  };
export default bridgePageEntry({
  id: "pages.icon-picker",
  title: "Icon picker",
  area: "Pages",
  page: "icon-picker",
  covers: [
    "page:cmux.icon-picker",
    "icon-picker/IconPicker.tsx",
    "icon-picker/VirtualGrid.tsx",
    "icon-picker/AssetTab.tsx",
  ],
  variants: {
    loaded: fixture(),
    empty: {
      ...fixture(),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-picker-search"));
        await ctx.type("no-such-emoji-gallery", { selector: ".icon-picker-search" });
      },
    },
    "long-content": {
      ...fixture(),
      note: "The full shipped emoji catalog; search has a long query.",
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".icon-picker-search"));
        await ctx.type("face with a very long descriptive search query that exceeds the search field", {
          selector: ".icon-picker-search",
        });
      },
    },
    error: {
      ...fixture("image"),
      failures: {
        "cmux.iconPicker.asset.fromURL": { code: "cmux.iconPicker.failed", message: "Sample asset download refused" },
      },
      play: assetPlay(true),
    },
    loading: { ...fixture("image"), pending: ["cmux.iconPicker.asset.fromURL"], play: assetPlay(false) },
  },
});
