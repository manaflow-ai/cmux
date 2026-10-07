// l10n-allow-file: gallery fixtures, not shipped UI.
import { bridgePageEntry, type BridgePageVariant } from "../../gallery/format";
import type { EditorConfig } from "./host";
function fixture(count: number): BridgePageVariant {
  const config: EditorConfig = {
    path: "/home/sample/projects/gallery/src/example.ts",
    hash: "sample-hash",
    text: Array.from(
      { length: count },
      (_, i) => `export const sample${i} = "${"Long sample text. ".repeat(count > 4 ? 12 : 1)}";`,
    ).join("\n"),
    settings: { autoSave: "off" },
  };
  return {
    streams: ["cmux.editor.changes", "cmux.editor.look"],
    replies: {
      "cmux.editor.config": count ? config : { pick: true },
      "cmux.editor.recents": { items: [] },
    },
    ...(count
      ? {
          play: async (ctx) => {
            await ctx.waitFor(() => ctx.document.documentElement.dataset.cmuxEditorHighlighted === "true");
          },
        }
      : {}),
  };
}
export default bridgePageEntry({
  id: "pages.editor",
  title: "Code editor",
  area: "Pages",
  page: "editor",
  covers: ["page:cmux.editor", "pages/editor/EditorPage.tsx"],
  variants: {
    empty: fixture(0),
    loaded: fixture(4),
    "long-content": fixture(40),
    error: {
      ...fixture(0),
      failures: {
        "cmux.editor.config": { code: "cmux.page.failed", message: "Sample owner is unavailable. Try again." },
      },
    },
    loading: { ...fixture(0), pending: ["cmux.editor.config"] },
  },
});
