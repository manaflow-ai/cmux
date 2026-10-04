// Boots the Cloud page (cmux-page://cmux.cloud/). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts); in the browser dev loop (`/cloud/?mock`) the in-memory mock provider
// stands in for the Cloud app server. The machine list layout comes from the page's init
// (README.md: Debug setting `cloud.machines.layout`).
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { parseLayout } from "./model";
import { PAGE_COMMAND } from "./ops";
import { CloudStore } from "./store";
import "./styles.css";

export function mountCloudPage(root: HTMLElement, client: PageClient | null = defaultClient()): CloudStore {
  const params = new URLSearchParams(location.search);
  const layout = parseLayout(document.documentElement.dataset.cloudMachinesLayout ?? params.get("layout"));
  const store = new CloudStore(client, { layout });
  // The page has no find or search field yet; it answers page commands as not handled so the
  // dispatcher can fall back. It never reads Cmd or Ctrl chords itself.
  client?.handle(PAGE_COMMAND, () => ({ handled: false }));
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("page.title");
  createRoot(root).render(<CloudPage store={store} strings={strings} />);
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
