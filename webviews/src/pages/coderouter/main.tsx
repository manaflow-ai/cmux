// Boots the CodeRouter page. In the app the host installs the `cmuxPage` bridge (pageClient.ts); in
// the browser dev loop (`/coderouter/?mock`, `?mock&signedout`) the in-memory mock provider stands
// in for the accounts service. DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import { CodeRouterPage } from "./CodeRouterPage";
import table from "./generated/strings.json";
import { MockCodeRouterProvider } from "./mockProvider";
import { CODEROUTER_PAGE, CodeRouterStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountCodeRouterPage(root: HTMLElement, client: PageClient | null = defaultClient()): CodeRouterStore {
  const state = openPageState(client, CODEROUTER_PAGE);
  const store = new CodeRouterStore(client);
  // The accounts service owns every row and the page has no field: it keeps its scroll only.
  state.keep(() => null);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(<CodeRouterPage store={store} strings={strings} />);
  return store;
}

function defaultClient(): PageClient | null {
  const query = new URLSearchParams(location.search);
  return createPageClient(
    query.has("mock") ? () => new MockCodeRouterProvider({ signedIn: !query.has("signedout") }) : undefined,
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "coderouter") mountCodeRouterPage(root);
