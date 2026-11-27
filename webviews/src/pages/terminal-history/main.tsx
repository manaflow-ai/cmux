import "../shared/desktop";
import "../shared/transientMaterial";
import { focusRoute } from "../../ui/focusRoute";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { renderLocalized } from "../shared/localizedRoot";
import table from "./generated/strings.json";
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
  // Start the bounded transcript read alongside the first React render.
  void store.load();
  if (client)
    void subscribePageStreams(client, {
      onCommand: ({ command, text }) => {
        if (command === "focusSearch" || command === "find") {
          if (typeof text === "string") void store.find(text);
          focusRoute(
            document.querySelector<HTMLInputElement>(".terminal-history-search input"),
            "person",
            "Find in terminal transcript",
          );
        }
      },
    });
  renderLocalized(
    createRoot(root),
    table,
    (strings) => <TerminalHistoryPage store={store} strings={strings} />,
    (strings) => strings.t("terminalHistory.tab"),
  );
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "terminal-history") mountTerminalHistoryPage(root);
