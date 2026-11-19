// Boots the Cloud page (cmux-page://cmux.cloud/). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts); in the browser dev loop (`/cloud/?mock`) the in-memory mock provider
// stands in for the Cloud app server. The machine list layout comes from the page's init
// (README.md: Debug setting `cloud.machines.layout`); the fragment `#/get` opens the storefront.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { parseLayout } from "./model";
import { PAGE_COMMAND } from "./ops";
import { CloudStore, parseView } from "./store";
import { StartTraceStore } from "./startTraceStore";
import { sampleTraceList, sampleTraces } from "./startTraceFixtures";
// The shared popup and dialog surface (ui.css imports it; this page loads no ui.css): the sheet role
// rule `.ui-dialog.ui-glass` draws this page's dialogs.
import "../../ui/popupSurface.css";
import "./styles.css";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";

export function mountCloudPage(root: HTMLElement, client: PageClient | null = defaultClient()): CloudStore {
  const params = new URLSearchParams(location.search);
  const layout = parseLayout(document.documentElement.dataset.cloudMachinesLayout ?? params.get("layout"));
  const store = new CloudStore(client, { layout, view: parseView(location.hash) });
  // Cloud start timings (DEV and NIGHTLY): read once the person is signed in; a build whose server
  // does not serve them answers unsupported, and the page shows no entry (startTraceStore.ts).
  const timings = new StartTraceStore(client);
  // `#/get` opens the storefront and `#/timings` the start timings; the host or a link may set either.
  window.addEventListener("hashchange", () => store.setView(parseView(location.hash)));
  // The fragment follows the view, so a later `#/get` link changes the hash and opens the storefront.
  let probed = false;
  store.subscribe(() => {
    const snapshot = store.getSnapshot();
    const view = snapshot.view;
    if (parseView(location.hash) !== view)
      history.replaceState(null, "", `${location.pathname}${location.search}${view === "machines" ? "" : `#/${view}`}`);
    if (!probed && snapshot.auth?.signedIn) {
      probed = true;
      void timings.refresh();
    }
  });
  // The page has no find or search field yet; it answers page commands as not handled so the
  // dispatcher can fall back. It never reads Cmd or Ctrl chords itself.
  client?.handle(PAGE_COMMAND, () => ({ handled: false }));
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <CloudPage store={store} strings={strings} timings={timings} />
    </UiProvider>,
  );
  return store;
}

/** `?mock` answers like the Cloud app server today; `?mock=all` also serves the ops it lacks. */
function defaultClient(): PageClient | null {
  const params = new URLSearchParams(location.search);
  const mock = params.has("mock");
  const unsupported = params.get("mock") === "all" ? [] : undefined;
  return createPageClient(
    mock
      ? () => {
          const provider = new MockCloudProvider({ unsupported });
          // `?mock=all` also serves the start timings, as a DEV or NIGHTLY build's server does.
          if (unsupported) {
            const now = Date.now();
            provider.startTraces = { list: sampleTraceList(now), traces: sampleTraces(now) };
          }
          return provider;
        }
      : undefined,
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "cloud") mountCloudPage(root);
