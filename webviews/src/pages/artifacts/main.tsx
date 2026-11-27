// Boots the Artifacts page (`cmux-page://cmux.artifacts/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/artifacts/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ArtifactsPage } from "./ArtifactsPage";
import { MockArtifactsProvider } from "./mockProvider";
import { ArtifactsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountArtifactsPage(root: HTMLElement, client: PageClient | null = defaultClient()): ArtifactsStore {
  const store = new ArtifactsStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("artifacts.page.title");
  createRoot(root).render(<ArtifactsPage store={store} strings={strings} />);
  void store.start();
  // Coming back to the tab reads the tree again: agents kept saving meanwhile.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.start();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockArtifactsProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "artifacts") mountArtifactsPage(root);
