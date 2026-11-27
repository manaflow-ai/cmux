// Boots the Forum page (cmux-page://cmux.forum/, behind experiments.forum). In the app the host
// installs the `cmuxPage` bridge (pageClient.ts) and relays `cmux.forum.*` to the daemon's forum
// owner; in the browser dev loop (`/forum/?mock`) the in-memory mock stands in for it.
import "../shared/desktop";
import { useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { createStrings, type Strings } from "../shared/i18n";
import table from "./generated/strings.json";
import { ForumPage } from "./ForumPage";
import { MockForumProvider } from "./mockProvider";
import { ForumStore } from "./store";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import "../shared/pageBase.css";
import "./styles.css";
import { appPopupHost } from "../shared/pagePopupHost";

function ForumRoot({ store, strings }: { store: ForumStore; strings: Strings }) {
  const state = useSyncExternalStore(store.subscribe, store.getState);
  return (
    <ForumPage
      snapshot={state.snapshot}
      strings={strings}
      layout="columns"
      now={Date.now()}
      intents={{
        openThread: (thread) => void store.openThread(thread),
        reply: (thread, body) => void store.reply(thread, body),
        post: (draft) => void store.post(draft),
      }}
    />
  );
}

export function mountForumPage(root: HTMLElement, client: PageClient | null = defaultClient()): ForumStore {
  const store = new ForumStore(client);
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.title = strings.t("forum.title");
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(strings.language)}>
      <ForumRoot store={store} strings={strings} />
    </UiProvider>,
  );
  return store;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockForumProvider() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "forum") mountForumPage(root);
