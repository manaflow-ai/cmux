// Boots the Bookmarks page (`cmux-page://cmux.bookmarks/`). In the app the host installs the
// `cmuxPage` bridge (pageClient.ts) and relays `cmux.bookmarks.*` to the daemon; in the browser dev
// loop (`/bookmarks/?mock`) the in-memory mock provider stands in for both.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { focusSearchField } from "../shared/searchField";
import { appPopupHost } from "../shared/pagePopupHost";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import table from "./generated/strings.json";
import { BookmarksPage } from "./BookmarksPage";
import { revealRoute } from "./model";
import { MockBookmarksProvider } from "./mockProvider";
import { BookmarksStore } from "./store";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";

export function mountBookmarksPage(root: HTMLElement, client: PageClient | null = defaultClient()): BookmarksStore {
  const strings = createStrings(table);
  const store = new BookmarksStore(client, {
    newFolderTitle: strings.t("folder.new"),
    onRevealed: () => history.replaceState(history.state, "", "#/"),
  });
  // A page opened to show one bookmark starts at `#/?reveal=<id>`: shown once the tree lands.
  const reveal = revealRoute(location.hash);
  if (reveal) store.reveal(reveal);
  // The app's key dispatcher sends page commands (Cmd-F is `find`); the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: (event) => {
        const { command, text } = event;
        if (command === "reset") store.resetQuery();
        // `reveal {bookmark}` (the bar's Show in Bookmarks Manager): show it in its folder.
        const bookmark = (event as { bookmark?: unknown }).bookmark ?? text;
        if (command === "reveal" && typeof bookmark === "string") store.reveal(bookmark);
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") store.setText(text);
        focusSearchField(document, ".bm-search");
      },
    });
  }
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <BookmarksPage store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockBookmarksProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "bookmarks") mountBookmarksPage(root);
