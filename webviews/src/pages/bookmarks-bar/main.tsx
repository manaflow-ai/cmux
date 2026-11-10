// Boots the bookmarks bar (`cmux-page://cmux.bookmarks-bar/`), one page per bookmarks bar on
// screen: CmuxNextBookmarks' BookmarksBarPages lends it to the browser tab whose bar is in a window
// and takes it back when that tab hides, so the pages follow the bars in sight, not the tabs. The
// host relays `cmux.bookmarks.*` reads to the daemon, serves the profile, icons and opening
// (`cmux.bookmarkPage.*`), and the native menus and the bar's writes (`cmux.bookmarksBar.*`). The
// bar lays out from its own rendered width.
import "../shared/desktop";
import { useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { BookmarksBar } from "../../browser-chrome/bookmarks-bar/BookmarksBar";
import { BookmarksBarStore } from "../../browser-chrome/bookmarks-bar/store";
import table from "./generated/strings.json";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "../../browser-chrome/bookmarks-bar/bookmarksBar.css";
import "./styles.css";

export function mountBookmarksBarPage(root: HTMLElement, client: PageClient | null): BookmarksBarStore {
  const strings = createStrings(table);
  const store = new BookmarksBarStore(client, {
    empty: strings.t("folder.empty"),
    openAll: (count) => strings.format("verb.openAll", String(count)),
  });
  const words = {
    barTitle: strings.t("root.bar"),
    more: strings.t("bar.more"),
    emptyHint: strings.t("bar.emptyHint"),
  };
  function Bar() {
    const snapshot = useSyncExternalStore(store.subscribe, store.getSnapshot);
    return (
      <BookmarksBar
        snapshot={snapshot}
        words={words}
        onOpen={(node, disposition) => store.open(node, disposition)}
        onFolder={(node, anchor) => void store.openFolder(node, anchor, node.title)}
        onOverflow={(shown, anchor) => void store.openOverflow(shown, anchor, words.more)}
        onOther={(anchor) => void store.openOther(anchor)}
        onContextMenu={(bookmark, point) => store.contextMenu(bookmark, point)}
        onMove={(id, slot) => void store.move(id, slot)}
        onDrop={(url, title, slot) => void store.drop(url, title, slot)}
        onIcons={(nodes) => void store.requestIcons(nodes)}
        onLayout={(laidOut) => store.report(laidOut)}
      />
    );
  }
  document.documentElement.lang = strings.language;
  document.title = words.barTitle;
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <Bar />
    </UiProvider>,
  );
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "bookmarks-bar")
  mountBookmarksBarPage(root, createPageClient());
