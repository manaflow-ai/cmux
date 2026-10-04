// Boots the History page. In the app the host installs the `cmuxPage` bridge (pageClient.ts); in
// the browser dev loop (`/history/?mock`) the in-memory mock provider stands in for the daemon.
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { HistoryPage } from "./HistoryPage";
import { MockHistoryProvider } from "./mockProvider";
import { HistoryStore } from "./store";
import { PAGE_COMMAND } from "./types";
import "./styles.css";

export function mountHistoryPage(root: HTMLElement, client: PageClient | null = defaultClient()): HistoryStore {
  const store = new HistoryStore(client, {
    writeClipboard: (text) => navigator.clipboard.writeText(text),
  });
  // The app's key dispatcher sends page commands (Cmd-F is `find`); the page never reads chords.
  client?.handle(PAGE_COMMAND, (params) => {
    const command = (params as { command?: string } | null)?.command;
    if (command !== "find" && command !== "focusSearch") return { handled: false };
    document.querySelector<HTMLInputElement>(".history-search")?.focus();
    return { handled: true };
  });
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(<HistoryPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockHistoryProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "history") mountHistoryPage(root);
