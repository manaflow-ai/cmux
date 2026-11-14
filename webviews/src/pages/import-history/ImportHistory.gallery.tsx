// l10n-allow-file: gallery fixtures, not shipped UI.
import { componentEntry } from "../../gallery/format";
import type { HistoryLayout } from "./ImportHistory";
import type { Phase } from "./model";

type Props = {
  layout?: HistoryLayout;
  phase?: Phase;
  empty?: boolean;
  paste?: boolean;
  autodetected?: boolean;
  open?: boolean;
};

export default componentEntry<Props>({
  id: "pages.import-history",
  title: "Bring your history",
  area: "Home and Chief",
  height: 800,
  widths: { narrow: 420, normal: 760, wide: 1100 },
  covers: [
    "page:cmux.import-history",
    "pages/import-history/ImportHistory.tsx",
    "pages/import-history/galleryFixture.tsx",
  ],
  load: async () => (await import("./galleryFixture")).ImportHistoryGallery,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    list: {
      note: "Recommended: one row per tool in alphabetical order; its checkbox brings chats and memories, and Sources opens them apart.",
      props: { layout: "list" },
    },
    "list-open": {
      note: "The same list with every tool's Sources open: Chats, then Memories, each source with its path.",
      props: { layout: "list", open: true },
    },
    chips: {
      note: "A Chats and a Memories toggle on each tool's row; picking a kind needs no disclosure, but every row is busier.",
      props: { layout: "chips" },
    },
    cards: {
      note: "Each tool its own card with every source listed; the most to read before the first click.",
      props: { layout: "cards" },
    },
    "nothing-detected": { props: { empty: true } },
    detecting: { props: { phase: "detecting" } },
    importing: { props: { phase: "importing", open: true } },
    done: { props: { phase: "done" } },
    error: { props: { phase: "error" } },
    "paste-summary": { props: { paste: true } },
    "paste-summary-open": {
      note: "A source's paste box open under its row: help, Copy, label and text box start at the title's edge, as the path does.",
      props: { paste: true, open: true },
    },
    autodetected: {
      note: "Archives found in the usual export folders are checked inline; manual pick remains available on each archive row.",
      props: { autodetected: true, open: true },
    },
  },
});
