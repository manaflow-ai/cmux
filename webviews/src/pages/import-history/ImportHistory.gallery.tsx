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
    groups: {
      note: "Recommended: two toggles, Chats and Memories, in one list; each source sits one level deeper behind Sources.",
      props: { layout: "groups" },
    },
    "groups-open": {
      note: "The same list with both groups' Sources open: sources in alphabetical order, each path under its name.",
      props: { layout: "groups", open: true },
    },
    sections: {
      note: "Each group its own card with every source always listed; more to read before the first click.",
      props: { layout: "sections" },
    },
    tiles: {
      note: "The two groups side by side; the summaries wrap sooner and the sources open under one tile only.",
      props: { layout: "tiles" },
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
