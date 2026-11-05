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
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    list: {
      note: "Recommended: one aligned list keeps every source visible and its action beside it.",
      props: { layout: "list" },
    },
    cards: {
      note: "Two columns trade a shorter list for more eye movement.",
      props: { layout: "cards" },
    },
    compact: {
      note: "A denser checklist for narrow or short panes.",
      props: { layout: "compact" },
    },
    "nothing-detected": { props: { empty: true } },
    detecting: { props: { phase: "detecting" } },
    importing: { props: { phase: "importing" } },
    done: { props: { phase: "done" } },
    error: { props: { phase: "error" } },
    "paste-summary": { props: { paste: true } },
    autodetected: {
      note: "Archives found in the usual export folders are checked inline; manual pick remains available on each archive row.",
      props: { autodetected: true },
    },
  },
});
