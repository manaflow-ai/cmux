// Boots the App Store page. In the app the host installs the `cmuxPage` bridge (pageClient.ts) and
// sets the route in the fragment (`#/discover?layout=grid`); in the browser dev loop
// (`/apps/?mock`) the in-memory mock provider stands in for the app supervisor.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { AppsPage } from "./AppsPage";
import table from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { CommunityStore } from "./community";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import "../shared/pageBase.css";
import "./styles.css";

export function mountAppsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
  hash = location.hash,
): AppsStore {
  const store = new AppsStore(client, hash);
  // The Community tab installs through the store's own path, so the consent card always shows.
  const community = new CommunityStore(client, (app) => store.install(app), hash);
  // The app's key dispatcher sends page commands; the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        const onCommunity = community.getSnapshot().active;
        if (command === "back") void (onCommunity ? community.select(undefined) : store.select(undefined));
        if (command === "reset") {
          store.setQuery("");
          store.setCategory(undefined);
          community.setQuery("");
        }
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") (onCommunity ? community : store).setQuery(text);
        document.querySelector<HTMLInputElement>(".apps-search")?.focus();
      },
    });
  }
  // The host opens a listing or the Installed tab on an open page by setting the fragment.
  window.addEventListener("hashchange", () => {
    store.applyRoute(window.location.hash);
    community.applyRoute(window.location.hash);
  });
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("store.window.title");
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <AppsPage store={store} strings={strings} community={community} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockAppsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "apps") mountAppsPage(root);
