// Boots the Agent Board page (`cmux-page://cmux.agent-board/`). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/agent-board/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { AgentBoardPage } from "./AgentBoardPage";
import { MockAgentBoardProvider } from "./mockProvider";
import { AgentBoardStore } from "./store";
import "../shared/pageBase.css";
import "../../ui/ui.css";
import "../../ui/controls.css";
import "./styles.css";

export function mountAgentBoardPage(root: HTMLElement, client: PageClient | null = defaultClient()): AgentBoardStore {
  const store = new AgentBoardStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("agentBoard.title");
  createRoot(root).render(<AgentBoardPage store={store} strings={strings} />);
  void store.start();
  // Coming back to the tab reads again: a turn of the setting elsewhere is not a folder change.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.refresh();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockAgentBoardProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "agent-board") mountAgentBoardPage(root);
