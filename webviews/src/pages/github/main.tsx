// Boots the GitHub page (`cmux-page://cmux.github/#/pull?url=…`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/github/?mock#/pull?url=…`) the mock provider stands in.
// The host moves an open page to another pull request by its route (`PageWebView.open(route:)`), so
// a second link is a route change in this page, never a new page. `#/issues?repo=…` and
// `#/issue?url=…` draw the issues view (GitHubIssues.tsx) in the same page.
import "../shared/desktop";
import "../shared/transientMaterial";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { holdFirstPaint } from "../shared/paintGate";
import table from "./generated/strings.json";
import { IssuesStore } from "./issuesStore";
import { MockGitHubProvider } from "./mockProvider";
import { GitHubRoot } from "./GitHubRoot";
import { GitHubStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountGitHubPage(root: HTMLElement, client: PageClient | null = defaultClient()): GitHubStore {
  const store = new GitHubStore(client);
  const issues = new IssuesStore(client);
  const strings = createStrings(table);
  document.title = strings.t("github.page.title");
  createRoot(root).render(<GitHubRoot store={store} issues={issues} strings={strings} />);
  // The first frame shown is the pull request the cache has, not "Loading…".
  void holdFirstPaint(Promise.all([store.route(location.hash), issues.route(location.hash)]));
  window.addEventListener("hashchange", () => {
    void store.route(location.hash);
    void issues.route(location.hash);
  });
  // Coming back to the tab asks again: a push or a review may have landed meanwhile.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    void store.ask();
    void issues.ask();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockGitHubProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "github") mountGitHubPage(root);
