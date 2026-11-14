// Boots the Machines section (`cmux-page://cmux.machines/`, the right sidebar's Machines section).
// In the app the host installs the `cmuxPage` bridge; in the browser dev loop (`/machines/?mock`)
// the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MachinesSection } from "./MachinesSection";
import { MockMachinesProvider } from "./mockProvider";
import { MachinesStore } from "./store";
// The shared popup and dialog surface (ui.css imports it; this page loads no ui.css): the sheet role
// rule `.ui-dialog.ui-glass` draws this page's dialogs.
import "../../ui/popupSurface.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountMachinesSection(root: HTMLElement, client: PageClient | null = defaultClient()): MachinesStore {
  const store = new MachinesStore(client);
  const strings = createStrings(table);
  createRoot(root).render(<MachinesSection store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  return createPageClient(mock !== null ? () => new MockMachinesProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "machines") mountMachinesSection(root);
