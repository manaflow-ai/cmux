// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { StashGalleryProps } from "./galleryFixture";

export default componentEntry<StashGalleryProps>({
  id: "pages.stash",
  title: "Stashed Tabs",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.stash", "pages/stash/StashPage.tsx#StashPage", "pages/stash/galleryFixture.tsx"],
  load: async () => (await import("./galleryFixture")).StashGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    normal: {
      note: "Recommended: three stashes, one compact line per page, a whole workspace with its tabs, and an untitled imported group.",
      props: {},
    },
    empty: { note: "Nothing stashed yet: the hint says where Save and Close is.", props: { stashes: "empty" } },
    "many-stashes": {
      note: "Twelve groups of long titles: rows truncate, group actions wrap in a narrow pane.",
      props: { stashes: "many" },
    },
    search: {
      note: "A search keeps the matching pages only; Restore All still takes the whole group.",
      props: { query: "typescript" },
    },
    "no-matches": { note: "A search that matches nothing.", props: { query: "zzz" } },
    "import-open": {
      note: "Import from OneTab… opens the paste box inline, above the list (never a sheet).",
      props: {
        importText:
          "https://a.example.test/ | A page\nhttps://b.example.test/\n\nhttps://c.example.test/ | Another group",
      },
    },
    disconnected: { note: "The stash owner is not connected.", props: { offline: true } },
  },
});
