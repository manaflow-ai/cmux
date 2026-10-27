// Boots the Files page (`cmux-page://cmux.files/`, cx-p4rt). In the app the host installs the
// `cmuxPage` bridge; in the browser dev loop (`/files/?mock`) the mock provider stands in.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { openPageState } from "../shared/pageState";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { FilesPage } from "./FilesPage";
import { MockFilesProvider } from "./mockProvider";
import { FILES_PAGE, FilesStore } from "./store";
import { FilesOps } from "./types";
import "../shared/pageBase.css";
import "./styles.css";

export function mountFilesPage(root: HTMLElement, client: PageClient | null = defaultClient()): FilesStore {
  const state = openPageState(client, FILES_PAGE);
  const store = new FilesStore(client, (text) => navigator.clipboard.writeText(text));
  state.keep(() => store.pageInputs());
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("files.page.title");
  createRoot(root).render(<FilesPage store={store} strings={strings} />);
  const scroller = () => root.querySelector<HTMLElement>(".files-scroll");
  // Before the host discards the hidden page: the open folders, the selection and the scroll its
  // next page goes back to, once its folders listed again (the next frame lays them out).
  client?.handle(FilesOps.viewState, () => store.viewState(scroller()?.scrollTop ?? 0));
  void store.start().then(() => {
    const scroll = store.takeRestoredScroll();
    if (scroll) requestAnimationFrame(() => scroller()?.scrollTo({ top: scroll }));
  });
  // Coming back to the tab lists the open folders again: an agent may have changed them.
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") void store.refresh();
  });
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockFilesProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "files") mountFilesPage(root);
