// The Set Up cmux card as its own small page, for the native Home (HomeSetupCard hosts it above
// Chief's composer). The React Home imports SetupCard itself, so this page goes once it ships.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { cardStrings } from "../home-messages/cards/strings";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { SetupCardPage } from "./SetupCardPage";
import { SetupCardStore } from "./store";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountSetupCard(root: HTMLElement, client: PageClient | null = createPageClient()): SetupCardStore {
  const store = new SetupCardStore(client);
  const strings = cardStrings();
  document.title = strings.t("home.setup.title");
  createRoot(root).render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <SetupCardPage store={store} />
    </UiProvider>,
  );
  void store.start();
  return store;
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "setup-card") mountSetupCard(root);
