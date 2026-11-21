// Boots the team board (`cmux-page://cmux.board/`). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts); in the browser dev loop the mock host stands in:
// `/board/?mock` (100 machines), `/board/?mock&machines=5000&rate=100` (5,000 machines, 100 changes
// a second), `&seed=N` for another board.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { BoardPage } from "./BoardPage";
import { MockBoardProvider } from "./mockProvider";
import { BoardStore } from "./store";
import "../shared/pageBase.css";
import "./styles.css";

export function mountBoardPage(root: HTMLElement, client: PageClient | null = defaultClient()): BoardStore {
  const store = new BoardStore(client);
  const strings = createStrings(table);
  document.title = strings.t("board.title");
  createRoot(root).render(<BoardPage store={store} strings={strings} />);
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const query = new URLSearchParams(location.search);
  if (!query.has("mock")) return createPageClient();
  // An absent or empty parameter keeps the default (`Number(null)` is 0, not "missing").
  const number = (key: string, fallback: number) => {
    const raw = query.get(key);
    const value = raw === null || raw.trim() === "" ? Number.NaN : Number(raw);
    return Number.isFinite(value) && value >= 0 ? value : fallback;
  };
  return createPageClient(
    () =>
      new MockBoardProvider({
        machines: number("machines", 100),
        seed: number("seed", 1),
        ratePerSecond: number("rate", 0),
      }),
  );
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "board") mountBoardPage(root);
