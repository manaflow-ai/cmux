// Boots the server card page (`cmux-page://cmux.server-cards/#/<card>`). In the app the host
// installs the `cmuxPage` bridge; in the browser dev loop (`/server-cards/?mock#/pair-invite`) the
// mock host stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockServerCardsHost } from "./mockHost";
import { ServerCardsPage } from "./ServerCardsPage";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "./styles.css";
import "./add-machine/addMachine.css";

export function mountServerCards(root: HTMLElement, client: PageClient | null = defaultClient()): void {
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("pairInvite.title");
  createRoot(root).render(<ServerCardsPage client={client} strings={strings} />);
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).get("mock");
  return createPageClient(mock !== null ? () => new MockServerCardsHost() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "server-cards") mountServerCards(root);
