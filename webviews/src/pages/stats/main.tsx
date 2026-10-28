// Boots the Stats page (`cmux-page://cmux.stats/`, hq#1920). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/stats/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockStatsProvider } from "./mockProvider";
import { StatsPage } from "./StatsPage";
import { STATS_PAGE, StatsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountStatsPage(root: HTMLElement, client: PageClient | null = defaultClient()): StatsStore {
  const state = openPageState(client, STATS_PAGE);
  const store = new StatsStore(client);
  state.keep(() => store.pageInputs());
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("stats.page.title");
  createRoot(root).render(<StatsPage store={store} strings={strings} />);
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
