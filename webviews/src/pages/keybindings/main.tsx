// Boots the Keyboard Shortcuts page (`cmux-page://cmux.keybindings/`). In the app the host
// installs the `cmuxPage` bridge (pageClient.ts); in the browser dev loop (`/keybindings/?mock`)
// the in-memory mock provider stands in for the app.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import table from "./generated/strings.json";
import { KeybindingsPage } from "./KeybindingsPage";
import { MockKeybindingsProvider, SAMPLE_TITLES, sampleLayers } from "./mockProvider";
import { KeybindingsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";
import { focusSearchField } from "../shared/searchField";

export function mountKeybindingsPage(root: HTMLElement, client: PageClient | null = defaultClient()): KeybindingsStore {
  const store = new KeybindingsStore(client);
  // The app's key dispatcher sends page commands (Cmd-F is `find`); the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "reset") store.resetQuery();
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") store.setText(text);
        focusSearchField(document, ".keys-search");
      },
    });
  }
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("keybindings.page.title");
  createRoot(root).render(<KeybindingsPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(
    mock ? () => new MockKeybindingsProvider(sampleLayers(), SAMPLE_TITLES, { captureDom: true }) : undefined,
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "keybindings") mountKeybindingsPage(root);
