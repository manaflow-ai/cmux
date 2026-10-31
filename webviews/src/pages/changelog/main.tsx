// Boots the changelog page (`cmux-page://cmux.changelog/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/changelog/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { holdFirstPaint } from "../shared/paintGate";
import { languageDirection, UiProvider } from "../../ui/UiProvider";
import table from "./generated/strings.json";
import { ChangelogPage } from "./ChangelogPage";
import { routeChipHost } from "./ChangePullRequest";
import { MockChangelogProvider } from "./mockProvider";
import { ChangelogStore, parseDesign, parseNewsLayout, parseSpan } from "./store";
import { mountUpdateSurface, parseSurface } from "./surface";
import "../shared/pageBase.css";
// The enlarged picture is a ui/Dialog, and a pull request's hover card a ui/Tooltip card with an
// Open in menu: this sheet places them (and the dialog's backdrop) over the page.
import "../../ui/ui.css";
import "./styles.css";

export function mountChangelogPage(root: HTMLElement, client: PageClient | null = defaultClient()): ChangelogStore {
  const store = new ChangelogStore(client);
  routeChipHost(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("changelog.page.title");
  const react = createRoot(root);
  const render = () =>
    react.render(
      // The pull request card's Open in menu follows the page's language direction (arrow keys, placement).
      <UiProvider container={root} dir={languageDirection(strings.language)}>
        <ChangelogPage
          store={store}
          strings={strings}
          design={parseDesign(location.hash)}
          news={parseNewsLayout(location.hash)}
        />
      </UiProvider>,
    );
  render();
  void store.start(parseSpan(location.hash));
  // The first frame shown is the final first screen, not "Loading…" (perceived speed).
  void holdFirstPaint(store.firstScreen());
  // The host moves an open page to a new update's span (`PageWebView.open(route:)`), and the
  // route carries the Debug Settings design.
  window.addEventListener("hashchange", () => {
    render();
    void store.setSpan(parseSpan(location.hash));
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockChangelogProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "changelog") {
  // The sidebar's update surfaces open this bundle on `#/surface/<kind>` (surface.tsx).
  const surface = parseSurface(location.hash);
  if (surface) mountUpdateSurface(root, surface, defaultClient());
  else mountChangelogPage(root);
}
