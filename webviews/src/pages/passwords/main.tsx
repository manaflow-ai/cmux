// Boots the Passwords page (`cmux-page://cmux.passwords/`). In the app the host installs the
// `cmuxPage` bridge (pageClient.ts); in the browser dev loop (`/passwords/?mock`, or
// `?mock=shipping` for the sections a build without the fork password API shows) the in-memory
// mock provider stands in for the app.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { subscribePageStreams } from "../shared/pageStreams";
import table from "./generated/strings.json";
import { MockPasswordsProvider, sampleData, shippingData } from "./mockProvider";
import { PasswordsPage } from "./PasswordsPage";
import { PasswordsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";
import { focusSearchField } from "../shared/searchField";

export function mountPasswordsPage(root: HTMLElement, client: PageClient | null = defaultClient()): PasswordsStore {
  const store = new PasswordsStore(client);
  // The app's key dispatcher sends page commands (Cmd-F is `find`); the page never reads chords.
  if (client) {
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "reset") store.resetQuery();
        if (command !== "find" && command !== "focusSearch") return;
        if (typeof text === "string") store.setText(text);
        focusSearchField(document, ".pw-search");
      },
    });
  }
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("passwords.page.title");
  createRoot(root).render(<PasswordsPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  return createPageClient(
    mock === null ? undefined : () => new MockPasswordsProvider(mock === "shipping" ? shippingData() : sampleData()),
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "passwords") mountPasswordsPage(root);
