import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { TerminalHistoryPage } from "./TerminalHistoryPage";
import { TerminalHistoryStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountTerminalHistoryPage(
  root: HTMLElement,
  client: PageClient | null = createPageClient(),
): TerminalHistoryStore {
  const key = new URLSearchParams(location.search).get("key") ?? "";
  const store = new TerminalHistoryStore(client, key);
  if (client)
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "focusSearch" || command === "find") {
          if (typeof text === "string") void store.find(text);
          document.querySelector<HTMLInputElement>(".terminal-history-search input")?.focus();
        }
      },
    });
  createRoot(root).render(<TerminalHistoryPage store={store} />);
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "terminal-history") mountTerminalHistoryPage(root);
