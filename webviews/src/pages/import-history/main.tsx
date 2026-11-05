import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ImportHistory } from "./ImportHistory";
import { ImportHistoryStore } from "./model";
import { MockImportHistoryProvider } from "./mockProvider";
import "../shared/pageBase.css";
import "./styles.css";

export function mountImportHistory(root: HTMLElement, client: PageClient | null = defaultClient()): ImportHistoryStore {
  const store = new ImportHistoryStore(client);
  const strings = createStrings(table);
  document.title = strings.t("history.title");
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <ImportHistory store={store} strings={strings} />
    </UiProvider>,
  );
  void store.start();
  return store;
}
function defaultClient(): PageClient | null {
  return createPageClient(
    new URLSearchParams(location.search).has("mock") ? () => new MockImportHistoryProvider() : undefined,
  );
}
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "import-history") mountImportHistory(root);
