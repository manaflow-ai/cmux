// Boots the Cloud page (cmux-page://cmux.cloud/). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts); in the browser dev loop (`/cloud/?mock`) the in-memory mock provider
// stands in for the Cloud app server. The machine list layout comes from the page's init
// (README.md: Debug setting `cloud.machines.layout`); the fragment `#/get` opens the storefront and
// `#/board` the team board (../board, over this page's bridge: board/cloudClient.ts).
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { parseLayout } from "./model";
import { PAGE_COMMAND } from "./ops";
import { CloudStore, parseView } from "./store";
// The shared popup and dialog surface (ui.css imports it; this page loads no ui.css): the sheet role
// rule `.ui-dialog.ui-glass` draws this page's dialogs.
import "../../ui/popupSurface.css";
import "./styles.css";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";
import { BoardPage } from "../board/BoardPage";
import { cloudBoardClient, isBoardRoute } from "../board/cloudClient";
import boardTable from "../board/generated/strings.json";
import { BoardStore } from "../board/store";
import "../board/styles.css";

export function mountCloudPage(root: HTMLElement, client: PageClient | null = defaultClient()): CloudStore {
  const params = new URLSearchParams(location.search);
  const layout = parseLayout(document.documentElement.dataset.cloudMachinesLayout ?? params.get("layout"));
  const store = new CloudStore(client, { layout, view: parseView(location.hash) });
  // `#/get` opens the storefront; the host or a link may set it on an open page.
  window.addEventListener("hashchange", () => store.setView(parseView(location.hash)));
  // The fragment follows the view, so a later `#/get` link changes the hash and opens the storefront.
  store.subscribe(() => {
    const view = store.getSnapshot().view;
    if (parseView(location.hash) !== view)
      history.replaceState(null, "", `${location.pathname}${location.search}${view === "get" ? "#/get" : ""}`);
  });
  // The page has no find or search field yet; it answers page commands as not handled so the
  // dispatcher can fall back. It never reads Cmd or Ctrl chords itself.
  client?.handle(PAGE_COMMAND, () => ({ handled: false }));
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <CloudOrBoard store={store} strings={strings} client={client} />
    </UiProvider>,
  );
  return store;
}

/**
 * The Cloud page, or at `#/board` the team board. The board's store starts on its first visit and
 * keeps its rows and stream while the page shows the machines again.
 */
function CloudOrBoard({ store, strings, client }: { store: CloudStore; strings: Strings; client: PageClient | null }) {
  const board = useSyncExternalStore(subscribeHash, () => isBoardRoute(location.hash));
  if (!board) return <CloudPage store={store} strings={strings} />;
  boardHost ??= startBoard(client);
  return (
    <div className="board-in-cloud">
      <BoardPage store={boardHost.store} strings={boardHost.strings} onBack={() => (location.hash = "#/")} />
    </div>
  );
}

let boardHost: { store: BoardStore; strings: Strings } | undefined;

function startBoard(client: PageClient | null) {
  const store = new BoardStore(client ? cloudBoardClient(client) : null);
  void store.start();
  return { store, strings: createStrings(boardTable) };
}

function subscribeHash(listener: () => void): () => void {
  window.addEventListener("hashchange", listener);
  return () => window.removeEventListener("hashchange", listener);
}

/** `?mock` answers like the Cloud app server today; `?mock=all` also serves the ops it lacks. */
function defaultClient(): PageClient | null {
  const params = new URLSearchParams(location.search);
  const mock = params.has("mock");
  const unsupported = params.get("mock") === "all" ? [] : undefined;
  return createPageClient(mock ? () => new MockCloudProvider({ unsupported }) : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "cloud") mountCloudPage(root);
