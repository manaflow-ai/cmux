// Boots the Cloud page (cmux-page://cmux.cloud/). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts); in the browser dev loop (`/cloud/?mock`) the in-memory mock provider
// stands in for the Cloud app server. The machine list layout comes from the page's init
// (README.md: Debug setting `cloud.machines.layout`); the fragment `#/get` opens the storefront.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { renderLocalized } from "../shared/localizedRoot";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { parseLayout } from "./model";
import { PAGE_COMMAND } from "./ops";
import { pageStorage } from "./machineCache";
import { CloudStore, parseView } from "./store";
// The shared popup and dialog surface (ui.css imports it; this page loads no ui.css): the sheet role
// rule `.ui-dialog.ui-glass` draws this page's dialogs.
import "../../ui/popupSurface.css";
import "./styles.css";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";

export function mountCloudPage(root: HTMLElement, client: PageClient | null = defaultClient()): CloudStore {
  const params = new URLSearchParams(location.search);
  const layout = parseLayout(document.documentElement.dataset.cloudMachinesLayout ?? params.get("layout"));
  // The page keeps its last machine list (machineCache.ts), so the next open draws it at once.
  const store = new CloudStore(client, { layout, view: parseView(location.hash), cache: pageStorage() });
  // `#/get` opens the storefront; the host or a link may set it on an open page.
  window.addEventListener("hashchange", () => store.setView(parseView(location.hash)));
  // The fragment follows the view, so a later `#/get` link changes the hash and opens the storefront.
  store.subscribe(() => {
    const view = store.getSnapshot().view;
    if (parseView(location.hash) !== view)
      history.replaceState(null, "", `${location.pathname}${location.search}${view === "get" ? "#/get" : ""}`);
  });
  // A failed payment may be fixed in the browser meanwhile: the billing state is read again each
  // time the page is shown or the app becomes active, never on a timer.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.refreshBilling();
  });
  window.addEventListener("focus", () => void store.refreshBilling());
  // The page has no find or search field yet; it answers page commands as not handled so the
  // dispatcher can fall back. It never reads Cmd or Ctrl chords itself.
  client?.handle(PAGE_COMMAND, () => ({ handled: false }));
  renderLocalized(
    createRoot(root),
    table,
    (strings) => (
      <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
        <CloudPage store={store} strings={strings} />
      </UiProvider>
    ),
    (strings) => strings.t("page.title"),
  );
  return store;
}

/** `?mock` answers like the Cloud app server today; `?mock=all` also serves the ops it lacks. */
function defaultClient(): PageClient | null {
  const params = new URLSearchParams(location.search);
  const mock = params.has("mock");
  const unsupported = params.get("mock") === "all" ? [] : undefined;
  return createPageClient(mock ? () => new MockCloudProvider({ unsupported }) : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "cloud") mountCloudPage(root);
