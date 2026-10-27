// Boots the Chief Usage page (`cmux-page://cmux.chief-usage/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/chief-usage/?mock`) the mock provider stands in.
// It reads once on mount and then only when the person changes the window or grouping or presses
// Refresh: no polling, no timers.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { openPageState, restoredPageInputs } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChiefUsagePage } from "./ChiefUsagePage";
import { MockChiefUsageProvider } from "./mockProvider";
import { CHIEF_USAGE_PAGE, ChiefUsageStore, restoredChiefUsageInputs } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountChiefUsagePage(root: HTMLElement, client: PageClient | null = defaultClient()): ChiefUsageStore {
  const state = openPageState(client, CHIEF_USAGE_PAGE);
  const store = new ChiefUsageStore(client, restoredChiefUsageInputs(restoredPageInputs(client, CHIEF_USAGE_PAGE)));
  state.keep(() => store.pageInputs());
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("chiefUsage.page.title");
  createRoot(root).render(<ChiefUsagePage store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockChiefUsageProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "chief-usage") mountChiefUsagePage(root);
