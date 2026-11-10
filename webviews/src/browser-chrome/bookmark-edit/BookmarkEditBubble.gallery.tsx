// l10n-allow-file: gallery fixtures (sample bookmarks and folders), not shipped UI.
// The omnibar star's edit bubble in three looks. The app draws `parity` (design/browser-chrome.md,
// "Bookmark edit bubble"): the native form's measures, so the move to React changes nothing a
// person sees. The stage shows the last command instead of closing, so every button can be tried.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import { BookmarkEditBubble } from "./BookmarkEditBubble";
import type { BookmarkEditCommand, BookmarkEditFolder, BookmarkEditLook, BookmarkEditState } from "./model";
import { bookmarkEditStrings } from "./strings";

type Props = { state: BookmarkEditState; look?: BookmarkEditLook };

const folders: BookmarkEditFolder[] = [
  { id: "bar", title: "Bookmarks Bar", depth: 0 },
  { id: "bm_work", title: "Work", depth: 1 },
  { id: "bm_docs", title: "Docs", depth: 2 },
  { id: "bm_reading", title: "Reading list", depth: 1 },
  { id: "other", title: "Other Bookmarks", depth: 0 },
];

// A profile past the 1,000 rows a level the app's popup host draws.
const manyFolders: BookmarkEditFolder[] = [
  { id: "bar", title: "Bookmarks Bar", depth: 0 },
  ...Array.from({ length: 1500 }, (_, n) => ({ id: `bm_many_${n}`, title: `Project ${n}`, depth: 1 + (n % 3) })),
  { id: "other", title: "Other Bookmarks", depth: 0 },
];

const added: BookmarkEditState = {
  revision: 1,
  isNew: true,
  title: "cmux: the terminal for agents",
  folder: "bar",
  folders,
  width: 320,
};

function BookmarkEditFixture({ state, look }: Props) {
  const [last, setLast] = useState<BookmarkEditCommand | null>(null);
  return (
    <div style={{ padding: 16, display: "flex", flexDirection: "column", gap: 8, alignItems: "flex-start" }}>
      <BookmarkEditBubble state={state} look={look} strings={bookmarkEditStrings()} onCommand={setLast} />
      <span style={{ font: "var(--text-caption) var(--font-ui)", color: "var(--ds-color-faint)" }}>
        {last ? `Sent: ${JSON.stringify(last)}` : " "}
      </span>
    </div>
  );
}

export default componentEntry<Props>({
  id: "browser-chrome.bookmark-edit",
  title: "Bookmark edit bubble",
  area: "Browser chrome",
  height: 260,
  widths: { narrow: 360, normal: 420, wide: 520 },
  covers: ["browser-chrome/bookmark-edit/BookmarkEditBubble.tsx", "page:cmux.bookmark-edit"],
  keywords: ["bookmark", "star", "bookmark added", "edit bookmark", "folder", "remove"],
  load: async () => BookmarkEditFixture,
  options: [
    {
      id: "look",
      label: "Look",
      kind: "choice",
      choices: [
        { value: "parity", label: "Parity (picked)" },
        { value: "compact", label: "Compact" },
        { value: "roomy", label: "Roomy" },
      ],
      defaultValue: "parity",
    },
  ],
  variants: {
    parity: {
      props: { state: added, look: "parity" },
      note: "Picked. The native form's measures: labels beside their fields, More… quiet on the start.",
    },
    compact: {
      props: { state: added, look: "compact" },
      note: "The popups' own padding; denser, but the buttons crowd the fields.",
    },
    roomy: {
      props: { state: added, look: "roomy" },
      note: "Labels over their fields; easier to scan, but the card is taller than the form it replaces.",
    },
    "parity-edit": {
      props: { state: { ...added, isNew: false, title: "Docs: bookmarks", folder: "bm_docs" }, look: "parity" },
      note: "A page already bookmarked: Edit Bookmark, in its nested folder.",
    },
    "parity-long-title": {
      props: {
        state: {
          ...added,
          title: "A very long page title that runs well past the width of the bubble's name field",
        },
        look: "parity",
      },
      note: "A long name scrolls in its field; the card keeps its width.",
    },
    "parity-many-folders": {
      props: { state: { ...added, folders: manyFolders, folder: "bm_many_1499" }, look: "parity" },
      note: "1,500 folders: the Folder menu draws the first 500 in tree order (and the current one), and its search field finds any other.",
    },
    "parity-gone-folder": {
      props: { state: { ...added, folder: "bm_deleted" }, look: "parity" },
      note: "A folder deleted while the bubble opened: the menu still shows it, so the value is never empty.",
    },
  },
});
