// Boots the Messages mirror page (`cmux-page://cmux.imessage/`). In the app the host installs the
// `cmuxPage` bridge and relays `cmux.imessage.*` to the daemon; in the browser dev loop
// (`/imessage/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ImessagePage } from "./ImessagePage";
import { MockImessageProvider } from "./mockProvider";
import { ImessageStore } from "./store";
import "../shared/pageBase.css";
import "../../theme/messages.css";
import "./styles.css";

export function mountImessagePage(root: HTMLElement, client: PageClient | null = defaultClient()): ImessageStore {
  const store = new ImessageStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("imessage.page.title");
  createRoot(root).render(<ImessagePage store={store} strings={strings} />);
  void store.start();
  // Back from System Settings (a Full Disk Access grant) or from Settings (the toggle): read the
  // state again. A ready page hears changes on its stream instead.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && store.getSnapshot().phase !== "ready") void store.refresh();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  if (mock === null) return createPageClient();
  return createPageClient(() => new MockImessageProvider(mock ? (mock as never) : "ready", Date.now(), { long: true }));
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "imessage") mountImessagePage(root);
