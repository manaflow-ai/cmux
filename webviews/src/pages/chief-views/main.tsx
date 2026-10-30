// Boots the Chief view gallery (`cmux-page://cmux.chief-views/`), the page the "Chief Views"
// action opens beside the Chief in Home. In the app the host installs the `cmuxPage` bridge; in the
// browser dev loop (`/chief-views/?mock`) the mock provider stands in. Agents arrive on the app's
// stream; Fleet and Landing read when a shown view needs them and on Refresh.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChiefViewsPage } from "./ChiefViewsPage";
import { MockChiefViewsProvider } from "./mockProvider";
import { CHIEF_VIEWS } from "./registry";
import { ChiefViewsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountChiefViewsPage(root: HTMLElement, client: PageClient | null = defaultClient()): ChiefViewsStore {
  const store = new ChiefViewsStore(client, CHIEF_VIEWS);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("chiefViews.page.title");
  createRoot(root).render(<ChiefViewsPage store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockChiefViewsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "chief-views") mountChiefViewsPage(root);
