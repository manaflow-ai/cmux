// Boots the Debug Settings page (`cmux-page://cmux.debug-settings/`). In the app the host installs
// the `cmuxPage` bridge (pageClient.ts); in the browser dev loop (`/debug-settings/?mock`) the
// in-memory mock provider stands in for the app.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import { focusSearchField } from "../shared/searchField";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import table from "./generated/strings.json";
import { DebugSettingsPage } from "./DebugSettingsPage";
import { MockDebugTunablesProvider } from "./mockProvider";
import { DebugSettingsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountDebugSettingsPage(root: HTMLElement, client: PageClient | null = defaultClient()): DebugSettingsStore {
  const store = new DebugSettingsStore(client, {
    writeClipboard: (text) => navigator.clipboard.writeText(text),
  });
  // The app's key dispatcher (and the window's Cmd-F) sends page commands; the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "reset") void store.setQuery("");
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") void store.setQuery(text);
        focusSearchField(document, ".ds-search");
      },
    });
  }
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("debugSettings.title");
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <DebugSettingsPage store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockDebugTunablesProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "debug-settings") mountDebugSettingsPage(root);
