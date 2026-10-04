// Boots the App Store page. In the app the host installs the `cmuxPage` bridge (pageClient.ts) and
// sets the route in the fragment (`#/discover?layout=grid`); in the browser dev loop
// (`/apps/?mock`) the in-memory mock provider stands in for the app supervisor.
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { AppsPage } from "./AppsPage";
import table from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountAppsPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
  hash = location.hash,
): AppsStore {
  const store = new AppsStore(client, hash);
  // The app's key dispatcher sends page commands; the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "back") void store.select(undefined);
        if (command === "reset") {
          store.setQuery("");
          store.setCategory(undefined);
        }
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") store.setQuery(text);
        document.querySelector<HTMLInputElement>(".apps-search")?.focus();
      },
    });
  }
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("store.window.title");
  createRoot(root).render(<AppsPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockAppsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "apps") mountAppsPage(root);
