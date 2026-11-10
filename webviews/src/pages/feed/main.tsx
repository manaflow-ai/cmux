// Boots the Feed page. The host sets the route in the fragment (`#/inbox`, `#/list?surface=sidebar`,
// `#/needs-you?style=rows`) and installs the `cmuxPage` bridge (pageClient.ts); in the browser dev
// loop (`/feed/?mock#/inbox`) the in-memory mock provider stands in for the daemon's feed client.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { appPopupHost } from "../shared/pagePopupHost";
import { subscribePageStreams } from "../shared/pageStreams";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import { FeedPage, rejectText } from "./FeedPage";
import table from "./generated/strings.json";
import { routeItem, withoutRouteItem } from "./model";
import { MockFeedProvider } from "./mockProvider";
import { FeedStore } from "./store";
import "../shared/pageBase.css";
import "../../ui/controls.css";
import "./styles.css";

export function mountFeedPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
  hash = location.hash || "#/inbox",
): FeedStore {
  const strings = createStrings(table);
  const { feedSurface, feedStyle } = document.documentElement.dataset;
  const store = new FeedStore(client, hash, {
    rejectText: (reject) => rejectText(reject, strings),
    attributes: { surface: feedSurface, style: feedStyle },
  });
  const surface = () => (document.documentElement.dataset.feedSurface = store.getSnapshot().route.surface);
  surface();
  // The app's request to show an item (`item=<id>`) is used once: dropped from the fragment, the same
  // request sent again (the person selected another item meanwhile) changes it and arrives.
  const consumeItem = () => {
    if (routeItem(location.hash)) history.replaceState(history.state, "", withoutRouteItem(location.hash));
  };
  consumeItem();
  // The app's key dispatcher sends page commands (Cmd-F is `find`); the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "reset") store.setQuery("");
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") store.setQuery(text);
        document.querySelector<HTMLInputElement>(".feed-filter")?.focus();
      },
    });
  }
  // The host moves an open page to another view or surface by setting the fragment.
  window.addEventListener("hashchange", () => {
    store.applyRoute(location.hash);
    consumeItem();
    surface();
  });
  document.title = strings.t(store.getSnapshot().route.view === "inbox" ? "feed.inboxTitle" : "feed.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <FeedPage store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const params = new URLSearchParams(location.search);
  return createPageClient(
    params.has("mock") ? () => new MockFeedProvider(undefined, { githubEnabled: params.has("github") }) : undefined,
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "feed") mountFeedPage(root);
