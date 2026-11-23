// Boots the App Store page. In the app the host installs the `cmuxPage` bridge (pageClient.ts) and
// sets the route in the fragment (`#/discover?layout=grid`); in the browser dev loop
// (`/apps/?mock`) the in-memory mock provider stands in for the app supervisor.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { renderLocalized } from "../shared/localizedRoot";
import { subscribePageStreams } from "../shared/pageStreams";
import { AppsPage } from "./AppsPage";
import table from "./generated/strings.json";
import { MockAppsProvider } from "./mockProvider";
import { AppsStore } from "./store";
import { NewTabChoice, NewTabChoiceProvider } from "./UseAsNewTab";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
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
  // The host opens a listing or the Installed tab on an open page by setting the fragment.
  window.addEventListener("hashchange", () => store.applyRoute(window.location.hash));
  const newTabChoice = new NewTabChoice(client);
  renderLocalized(
    createRoot(root),
    table,
    (strings) => (
      <UiProvider container={root} dir={languageDirection(strings.language)}>
        <NewTabChoiceProvider value={newTabChoice}>
          <AppsPage store={store} strings={strings} />
        </NewTabChoiceProvider>
      </UiProvider>
    ),
    (strings) => strings.t("store.window.title"),
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockAppsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "apps") mountAppsPage(root);
