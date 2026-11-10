// l10n-allow-file: gallery fixtures (sample bookmarks and the bar's words), not shipped UI.
// The bookmarks bar under a browser toolbar, over sample rows in three looks. The app draws
// `parity` (design/browser-chrome.md "Bookmarks bar"): the native bar's look, so the move to React
// changes nothing a person sees. Clicks and drops show what the page would send.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { sampleBookmarks } from "../../pages/bookmarks/mockProvider";
import type { Bookmark } from "../../pages/bookmarks/types";
import { BookmarksBar, type BarLook } from "./BookmarksBar";
import type { BarSnapshot } from "./store";

type Props = { look?: BarLook; width?: number; items?: Bookmark[]; hasOther?: boolean; loaded?: boolean };

const words = {
  barTitle: "Bookmarks Bar",
  more: "More Bookmarks",
  emptyHint: "Drag a link here or click the star to add bookmarks",
};

function barRow(): Bookmark[] {
  return sampleBookmarks()
    .filter((node) => node.parent === "bar")
    .map((node, index) => ({ ...node, index }));
}

/** Many links on the bar: the page renders only those that fit. */
function longRow(count = 5_000): Bookmark[] {
  return Array.from({ length: count }, (_, index) => ({
    id: `bm_bar_${index}`,
    browser_profile_id: "default",
    parent: "bar",
    kind: "url" as const,
    index,
    title: `Saved page ${index + 1}`,
    url: `https://site-${index + 1}.example/`,
    created_ms: 0,
  }));
}

function BarFixture({ look = "parity", width = 640, items = barRow(), hasOther, loaded = true }: Props) {
  const [said, setSaid] = useState("");
  const snapshot: BarSnapshot = {
    loaded,
    profile: "default",
    otherTitle: "Other Bookmarks",
    revision: 1,
    otherRevision: 1,
    items,
    // Loading is the strip alone: nothing is known about Other Bookmarks yet.
    hasOther: hasOther ?? loaded,
    icons: {},
  };
  const say = (what: string) => () => setSaid(what);
  return (
    <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ width, maxWidth: "100%", background: "var(--ds-color-surface)", borderRadius: 8 }}>
        <BookmarksBar
          snapshot={snapshot}
          words={words}
          look={look}
          onOpen={(node, disposition) => setSaid(`open ${node.title || node.url} (${disposition})`)}
          onFolder={(node) => setSaid(`folder menu: ${node.title}`)}
          onOverflow={(shown) => setSaid(`overflow menu: ${items.length - shown} items`)}
          onOther={say("Other Bookmarks menu")}
          onContextMenu={(id) => setSaid(`context menu: ${id ?? "bar"}`)}
          onMove={(id, slot) => setSaid(`move ${id} to ${slot}`)}
          onDrop={(url, title, slot) => setSaid(`add ${title || url} at ${slot}`)}
          onIcons={() => undefined}
        />
      </div>
      <span style={{ font: "var(--text-caption) var(--font-ui)", color: "var(--ds-color-faint)" }}>{said || " "}</span>
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.bookmarks-bar",
  title: "Bookmarks bar",
  area: "Browser chrome",
  height: 120,
  widths: { narrow: 360, normal: 640, wide: 960 },
  covers: ["page:cmux.bookmarks-bar", "browser-chrome/bookmarks-bar/BookmarksBar.tsx", "pages/bookmarks/glyphs.tsx"],
  keywords: ["bookmarks bar", "favorites", "toolbar", "overflow", "other bookmarks", "drop a link"],
  load: async () => BarFixture,
  styles: async () => {
    await import("../../ui/ui.css");
    await import("./bookmarksBar.css");
  },
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "parity", label: "Parity (picked)" },
        { value: "tonal", label: "Tonal" },
        { value: "dense", label: "Dense" },
      ],
      defaultValue: "parity",
    },
  ],
  variants: {
    parity: {
      props: { look: "parity" },
      note: "Picked. The native bar's look: no fill at rest, the gray hover fill, the pressed fill at once.",
    },
    tonal: {
      props: { look: "tonal" },
      note: "Every item keeps a faint fill at rest: the targets read as buttons, but the strip turns busy under every tab.",
    },
    dense: {
      props: { look: "dense" },
      note: "Tighter padding and no gap: more items fit before the chevron, but titles run into each other.",
    },
    overflow: {
      props: { look: "parity", width: 360 },
      note: "A narrow pane: what does not fit goes behind the chevron; Other Bookmarks keeps the end.",
    },
    "only-other": {
      props: { look: "parity", items: [] },
      note: "Nothing on the bar, something in Other Bookmarks: the hint, and the Other Bookmarks button.",
    },
    long: {
      props: { look: "parity", items: longRow() },
      note: "Five thousand links on the bar: only those that fit are rendered.",
    },
    loading: {
      props: { look: "parity", loaded: false, items: [] },
      note: "Before the first read: the strip only (the host keeps the page hidden until it reports a layout).",
    },
  },
});
