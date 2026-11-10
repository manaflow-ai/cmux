// l10n-allow-file: gallery fixtures, public-safe chrome and sample tab labels.
import { componentEntry } from "../format";
import { FolderTabs, type FolderTabsProps } from "./FolderTabs";

// Leo, 2026-11-10: "The selected tab should be white as well ... We can like morph it in as like, you
// know how folder tabs look, right? Like just integrate that. Like make it look cohesive. Make it look
// good." The theme axis gives light and dark, the background axis an image behind the window.
const variants: Record<string, { props: FolderTabsProps; note: string }> = {
  "goo-r8": {
    props: { shape: "goo", fillet: 8, radius: 6, join: "seamless", selected: 1 },
    note: "ships: 8 pt concave fillets into the content, 6 pt tab corners, no border (chrome.cornerFlush flush-goo)",
  },
  "goo-r8-first-tab": {
    props: { shape: "goo", fillet: 8, radius: 6, join: "seamless", selected: 0 },
    note: "the first tab selected: the content's edge rises straight into it, no fillet on that side",
  },
  "goo-r4": {
    props: { shape: "goo", fillet: 4, radius: 6, join: "seamless", selected: 1 },
    note: "4 pt fillets: tighter, reads more like a tab sitting on the edge",
  },
  "goo-r12": {
    props: { shape: "goo", fillet: 12, radius: 8, join: "seamless", selected: 1 },
    note: "12 pt fillets, 8 pt corners: softer, the goo Leo described, but crowds a narrow strip",
  },
  square: {
    props: { shape: "square", fillet: 0, radius: 6, join: "seamless", selected: 1 },
    note: "no fillets (chrome.cornerFlush flush): sharp inner corners where the tab meets the content",
  },
  "goo-r8-hairline": {
    props: { shape: "goo", fillet: 8, radius: 6, join: "hairline", selected: 1 },
    note: "the same shape with a hairline along the folder and the content's edge",
  },
  "pill-before": {
    props: { shape: "pill", fillet: 0, radius: 6, join: "seamless", selected: 1 },
    note: "before: the gray pill on the strip, apart from the content (chrome.cornerFlush off)",
  },
};

export default componentEntry<FolderTabsProps>({
  id: "native.folder-tabs",
  title: "Selected tab is the foreground",
  area: "Native",
  height: 340,
  widths: { narrow: 800, normal: 800, wide: 800 },
  // The native tab strip's selected folder tab (TabCell+CornerFeet.swift), drawn as a fixture.
  covers: ["swift:TabCell"],
  load: async () => FolderTabs,
  styles: () => import("./FolderTabs.css"),
  variants,
});
