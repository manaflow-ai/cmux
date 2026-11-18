// l10n-allow-file: gallery fixtures (sample bookmarks, typed text), not shipped UI.
// The Bookmarks page (cmux-page://cmux.bookmarks/): the same BookmarksPage main.tsx mounts, over
// the mock `cmux.bookmarks.*` provider instead of the host bridge. `two-pane` ships; `breadcrumb`
// and `compact` are the layouts it was picked against.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { BookmarksPage, type BookmarksLayout } from "./BookmarksPage";
import { longBookmarks, MockBookmarksProvider, sampleBookmarks, type MockOptions } from "./mockProvider";
import { BookmarksStore } from "./store";
import type { Bookmark } from "./types";

type Props = {
  layout?: BookmarksLayout;
  listing?: Bookmark[];
  options?: MockOptions;
  /** The title of the folder to show (the bar when unset). */
  folder?: string;
  text?: string;
  /** Titles of the rows to select. */
  select?: string[];
  /** Open the editor: Edit on the row with this title, or an add. */
  edit?: string;
  add?: "bookmark" | "folder";
  /** Type this URL into the open editor and press Save. */
  typeURL?: string;
};

function BookmarksGallery({ layout, listing, options, folder, text, select = [], edit, add, typeURL }: Props) {
  const [strings] = useState(() => createStrings(table));
  const [store] = useState(
    () =>
      new BookmarksStore(new MockBookmarksProvider(listing ?? sampleBookmarks(), options), {
        newFolderTitle: strings.t("folder.new"),
        newKey: () => "gallery",
      }),
  );
  const [setup] = useState(() => ({ folder, text, select, edit, add, typeURL }));
  useEffect(() => {
    void store.start().then(async () => {
      const byTitle = (title: string) =>
        [...store.getSnapshot().tree.nodes.values()].find((node) => node.title === title);
      if (setup.folder) {
        const shown = byTitle(setup.folder);
        if (shown) store.showFolder(shown.id);
      }
      if (setup.text) {
        store.setText(setup.text);
        await new Promise((done) => setTimeout(done, 0));
      }
      for (const [index, title] of setup.select.entries()) {
        const node = byTitle(title);
        if (node) store.select(node.id, index === 0 ? "single" : "toggle");
      }
      const editing = setup.edit ? byTitle(setup.edit) : undefined;
      if (editing) store.startEdit(editing);
      if (setup.add === "bookmark") store.startAddBookmark();
      if (setup.add === "folder") store.startAddFolder();
      if (setup.typeURL !== undefined) {
        store.setEditor({ title: "Notes", url: setup.typeURL });
        await store.commitEditor();
      }
    });
  }, [store, setup]);
  return <BookmarksPage store={store} strings={strings} layout={layout} />;
}

const emptyFolder: Bookmark[] = [
  ...sampleBookmarks(),
  {
    id: "bm_empty",
    browser_profile_id: "default",
    parent: "other",
    kind: "folder",
    index: 2,
    title: "Recipes",
    created_ms: 0,
  },
];

export default componentEntry<Props>({
  id: "pages.bookmarks",
  title: "Bookmarks",
  area: "Pages",
  height: 560,
  widths: { narrow: 380, normal: 720, wide: 960 },
  covers: ["page:cmux.bookmarks", "pages/bookmarks/BookmarksPage.tsx", "pages/bookmarks/BookmarkEditor.tsx"],
  load: async () => BookmarksGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("../../ui/ui.css");
    await import("./styles.css");
  },
  variants: {
    "two-pane": {
      note: "Ships. The folder tree beside the Work folder's list; below 480 px the tree gives way to the breadcrumb.",
      props: { folder: "Work", select: ["Pull requests"] },
    },
    breadcrumb: {
      note: "Alternative: one list with the folder path above it; folders are entered and left by the path.",
      props: { layout: "breadcrumb", folder: "Work", select: ["Pull requests"] },
    },
    compact: {
      note: "Alternative: one list, 24 px rows, titles only (the URL is the row's tooltip).",
      props: { layout: "compact", folder: "Work", select: ["Pull requests"] },
    },
    bar: { note: "The Bookmarks Bar on open: folders and links in bar order.", props: {} },
    "multi-select": {
      note: "Two rows selected with Cmd-click; Delete removes both, a drag carries both.",
      props: { select: ["GitHub", "Reading"] },
    },
    "empty-folder": {
      note: "An empty folder: the empty title and hint, the tree still shows where it is.",
      props: { listing: emptyFolder, folder: "Recipes" },
    },
    "search-matches": {
      note: "A search across every folder: each row says where it lives (Bookmarks Bar › Work › Docs).",
      props: { text: "rust" },
    },
    "search-none": {
      note: "A search with no matches.",
      props: { text: "zzzz" },
    },
    "editor-edit": {
      note: "Edit on a bookmark: Name, URL, Folder; Return saves, Escape cancels.",
      props: { folder: "Work", edit: "Linear" },
    },
    "editor-rename": {
      note: "Rename on a folder: no URL, and its own subtree is not offered as a destination.",
      props: { edit: "Work" },
    },
    "editor-add-folder": {
      note: "Add Folder from the More menu, in the shown folder, named New Folder.",
      props: { folder: "Reading", add: "folder" },
    },
    "editor-invalid-url": {
      note: "Save with a URL that is not one: the dialog stays open and says so.",
      props: { add: "bookmark", typeURL: "not a url" },
    },
    "editor-refused": {
      note: "The daemon refused the save: its message shows in the dialog.",
      props: {
        add: "bookmark",
        typeURL: "example.com",
        options: { refuse: { code: "limit", message: "This profile holds the most bookmarks it can." } },
      },
    },
    long: {
      note: "Two thousand links in one folder: the list draws only the rows on screen.",
      props: { listing: longBookmarks(), folder: "Archive" },
    },
    disconnected: {
      note: "The app lost its daemon link: the page says so after the grace.",
      props: { options: { disconnected: true } },
    },
  },
});
