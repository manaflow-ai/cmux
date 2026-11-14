// Boots the Cloud progress page (`cmux-page://cmux.cloud-progress/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/cloud-progress/?mock`) the mock provider stands in and
// walks a new machine through its stages.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { CloudProgressPage } from "./CloudProgressPage";
import { MockCloudProgressProvider } from "./mockProvider";
import { CloudProgressStore } from "./store";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";

export function mountCloudProgressPage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
): CloudProgressStore {
  const store = new CloudProgressStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("cloudProgress.title.new");
  createRoot(root).render(<CloudProgressPage store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  return createPageClient(mock !== null ? () => new MockCloudProgressProvider({ walk: true }) : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "cloud-progress") mountCloudProgressPage(root);
