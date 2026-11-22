// Boots the changelog page (`cmux-page://cmux.changelog/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/changelog/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ChangelogPage } from "./ChangelogPage";
import { MockChangelogProvider } from "./mockProvider";
import { ChangelogStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountChangelogPage(root: HTMLElement, client: PageClient | null = defaultClient()): ChangelogStore {
  const store = new ChangelogStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("changelog.page.title");
  createRoot(root).render(<ChangelogPage store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockChangelogProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "changelog") mountChangelogPage(root);
