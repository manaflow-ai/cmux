import { useSyncExternalStore } from "react";
import type { Strings } from "../shared/i18n";
import { ForumPage } from "./ForumPage";
import type { ForumStore } from "./store";

export function ForumRoot({ store, strings }: { store: ForumStore; strings: Strings }) {
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
