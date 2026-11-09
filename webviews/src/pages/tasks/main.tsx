// Boots the Tasks page (`cmux-page://cmux.tasks/`). In the app the host installs the `cmuxPage`
// bridge (pageClient.ts) and relays `cmux.tasks.*` to the daemon, which relays to the local Tasks
// owner; in the browser dev loop (`/tasks/?mock`) the in-memory mock owner stands in.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
import { useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockTasksProvider } from "./mockProvider";
import { followTasksPalette } from "./palette";
import { parseLayout, parseRoute } from "./route";
import { TasksStore } from "./store";
import { TasksPage } from "./TasksPage";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { appPopupHost } from "../shared/pagePopupHost";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

const CLIPBOARD_WRITE = "cmux.app.clipboard.write";

/** `<html data-tasks-layout>`, live: the host sets it from the `tasks.layout` setting. */
function subscribeLayout(listener: () => void): () => void {
  const observer = new MutationObserver(listener);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-tasks-layout"] });
  return () => observer.disconnect();
}
const readLayout = () => parseLayout(document.documentElement.dataset.tasksLayout);

function Root({
  store,
  copy,
  strings,
}: {
  store: TasksStore;
  copy: (text: string) => void;
  strings: ReturnType<typeof createStrings>;
}) {
  const layout = useSyncExternalStore(subscribeLayout, readLayout, readLayout);
  return <TasksPage store={store} strings={strings} layout={layout} copy={copy} />;
}

export function mountTasksPage(root: HTMLElement, client: PageClient | null = defaultClient()): TasksStore {
  const store = new TasksStore(client);
  let lastNew: string | undefined;
  const applyRoute = () => {
    const route = parseRoute(location.hash);
    if (route.scope) store.setScope(route.scope);
    if (route.newTask && route.newTask !== lastNew) {
      lastNew = route.newTask;
      store.requestNewTask();
    }
  };
  applyRoute();
  window.addEventListener("hashchange", applyRoute);
  followTasksPalette(document.documentElement);
  // The native pasteboard first: `navigator.clipboard` may be missing on the page's custom origin.
  const copy = (text: string) => {
    const web = () => navigator.clipboard?.writeText(text) ?? Promise.reject(new Error("no clipboard"));
    void (client ? client.call(CLIPBOARD_WRITE, { text }).catch(web) : web()).catch(() => {});
  };
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("pane.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <Root store={store} copy={copy} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockTasksProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "tasks") mountTasksPage(root);
