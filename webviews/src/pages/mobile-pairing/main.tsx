// Boots the Mobile Pairing page (`cmux-page://cmux.mobile-pairing/`). In the app the host installs
// the `cmuxPage` bridge; in the browser dev loop (`/mobile-pairing/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockMobilePairingProvider } from "./mockProvider";
import { MobilePairingPage } from "./MobilePairingPage";
import { MOBILE_PAIRING_PAGE, MobilePairingStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountMobilePairingPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): MobilePairingStore {
  const state = openPageState(client, MOBILE_PAIRING_PAGE);
  const store = new MobilePairingStore(client);
  // The host owns the pairing status and the switch, and the page has no field: it keeps its scroll.
  state.keep(() => null);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("mobilePairing.page.title");
  createRoot(root).render(<MobilePairingPage store={store} strings={strings} />);
  void store.start();
  // Coming back to the tab reads the status again (a code may have expired meanwhile).
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.refresh();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  return createPageClient(mock !== null ? () => new MockMobilePairingProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "mobile-pairing") mountMobilePairingPage(root);
