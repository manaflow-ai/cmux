import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { ArtifactsPage } from "./ArtifactsPage";
import { MockArtifactsProvider } from "./mockProvider";
import { ArtifactsStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";
export function mountArtifactsPage(root: HTMLElement, client: PageClient | null = defaultClient()) {
  const store = new ArtifactsStore(client);
  document.title = "Artifacts";
  createRoot(root).render(<ArtifactsPage store={store} />);
  return store;
}
function defaultClient(): PageClient | null { return new URLSearchParams(location.search).has("mock") ? new MockArtifactsProvider() : createPageClient(); }
const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "artifacts") mountArtifactsPage(root);
