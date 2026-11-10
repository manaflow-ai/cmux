// Boots the Task Manager page (`cmux-page://cmux.task-manager/`). In the app the host installs the
// `cmuxPage` bridge and pushes a sample about once a second while the page is open
// (CmuxNextApp TaskManagerPageService); in the browser dev loop (`/task-manager/?mock`) the mock
// host stands in. DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import { appPopupHost } from "../shared/pagePopupHost";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import table from "./generated/strings.json";
import { MockTaskManagerProvider } from "./mockProvider";
import { TaskManagerRoot } from "./TaskManagerPage";
import { TaskManagerStore } from "./store";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountTaskManagerPage(root: HTMLElement, client: PageClient | null = defaultClient()): TaskManagerStore {
  const store = new TaskManagerStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("taskManager.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <TaskManagerRoot store={store} strings={strings} />
    </UiProvider>,
  );
  void store.start();
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockTaskManagerProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "task-manager") mountTaskManagerPage(root);
