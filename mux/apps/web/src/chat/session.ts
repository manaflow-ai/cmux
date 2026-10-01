import type { ID } from "@mux/protocol";
import { StackAuth } from "../auth/stack.ts";
import { ConversationStore } from "./conversation-store.ts";
import { httpSource } from "./http-source.ts";
import type { ChatSource } from "./source.ts";

export interface ChatSession {
  auth: StackAuth;
  source: ChatSource;
  store(conversationId: ID, viewerId: ID): ConversationStore;
}

export function makeSession(onMessage: () => void): ChatSession {
  const auth = new StackAuth();
  const source = httpSource({ baseUrl: "", credential: () => auth.credential() });
  const stores = new Map<ID, ConversationStore>();
  return {
    auth,
    source,
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
