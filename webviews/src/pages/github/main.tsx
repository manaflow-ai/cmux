// Boots the GitHub page (`cmux-page://cmux.github/#/pull?url=…`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/github/?mock#/pull?url=…`) the mock provider stands in.
// The host moves an open page to another pull request by its route (`PageWebView.open(route:)`), so
// a second link is a route change in this page, never a new page.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { holdFirstPaint } from "../shared/paintGate";
import table from "./generated/strings.json";
import { GitHubPage } from "./GitHubPage";
import { MockGitHubProvider } from "./mockProvider";
import { GitHubStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountGitHubPage(root: HTMLElement, client: PageClient | null = defaultClient()): GitHubStore {
  const store = new GitHubStore(client);
  const strings = createStrings(table);
  document.title = strings.t("github.page.title");
  createRoot(root).render(<GitHubPage store={store} strings={strings} />);
  // The first frame shown is the pull request the cache has, not "Loading…".
  void holdFirstPaint(store.route(location.hash));
  window.addEventListener("hashchange", () => void store.route(location.hash));
  // Coming back to the tab asks again: a push or a review may have landed meanwhile.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.ask();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockGitHubProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "github") mountGitHubPage(root);
