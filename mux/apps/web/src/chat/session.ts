import type { ID } from "@mux/protocol";
import { StackAuth } from "../auth/stack.ts";
import { ConversationStore } from "./conversation-store.ts";
import { httpSource } from "./http-source.ts";
import type { ChatSource } from "./source.ts";

export interface ChatSession {
  auth: StackAuth;
  source: ChatSource;
  store(conversationId: ID, viewerId: ID): ConversationStore;
  /** Starts following server-side list changes (once; call after sign-in). */
  watchList(): void;
}

/** `onMessage` refreshes conversation lists; it runs on new messages and on server list changes. */
export function makeSession(onMessage: () => void): ChatSession {
  const auth = new StackAuth();
  const source = httpSource({ baseUrl: "", credential: () => auth.credential() });
  const stores = new Map<ID, ConversationStore>();
  let watching = false;
  return {
    auth,
    source,
    watchList() {
      if (watching) return;
      watching = true;
      source.watchConversations(onMessage);
    },
    store(conversationId, viewerId) {
      let store = stores.get(conversationId);
      if (!store) {
        store = new ConversationStore(source, conversationId, viewerId, onMessage);
        stores.set(conversationId, store);
      }
      return store;
    },
  };
}
