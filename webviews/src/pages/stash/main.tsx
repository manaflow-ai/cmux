// Boots the Stashed Tabs page. In the app the host installs the `cmuxPage` bridge (pageClient.ts);
// in the browser dev loop (`/stash/?mock`) the in-memory mock provider stands in for the owners.
// The route `#/import` opens the OneTab paste box (Import from OneTab… on a page not open yet).
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { StashPage } from "./StashPage";
import { MockStashProvider } from "./mockProvider";
import { StashStore } from "./store";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import "../shared/pageBase.css";
import "./styles.css";
import { appPopupHost } from "../shared/pagePopupHost";

export function mountStashPage(root: HTMLElement, client: PageClient | null = defaultClient()): StashStore {
  const store = new StashStore(client, { importOpen: location.hash === "#/import" });
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("stash.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <StashPage store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockStashProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "stash") mountStashPage(root);
