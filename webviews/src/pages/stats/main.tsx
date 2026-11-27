// Boots the Stats page (`cmux-page://cmux.stats/`, hq#1920). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/stats/?mock`) the mock provider stands in.
import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { renderLocalized } from "../shared/localizedRoot";
import table from "./generated/strings.json";
import { MockStatsProvider } from "./mockProvider";
import { StatsPage } from "./StatsPage";
import { StatsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountStatsPage(root: HTMLElement, client: PageClient | null = defaultClient()): StatsStore {
  const store = new StatsStore(client);
  renderLocalized(
    createRoot(root),
    table,
    (strings) => <StatsPage store={store} strings={strings} />,
    (strings) => strings.t("stats.page.title"),
  );
  void store.start();
  // Coming back to the tab reads the logs again: agents kept working meanwhile.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.refresh();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockStatsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "stats") mountStatsPage(root);
