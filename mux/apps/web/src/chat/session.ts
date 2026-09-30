import type { ID } from "@mux/protocol";
import { ConversationStore } from "./conversation-store.ts";
import { httpSource } from "./http-source.ts";
import type { ChatSource } from "./source.ts";

/** Development identity until Stack Auth lands: `?dev_user=name` once, then remembered. */
function devUser(): string {
  const fromUrl = new URL(window.location.href).searchParams.get("dev_user");
  try {
    if (fromUrl) localStorage.setItem("mux.devUser", fromUrl);
    return fromUrl ?? localStorage.getItem("mux.devUser") ?? "lawrence";
  } catch {
    return fromUrl ?? "lawrence";
  }
}

export interface ChatSession {
  source: ChatSource;
  store(conversationId: ID, viewerId: ID): ConversationStore;
}

export function makeSession(onMessage: () => void): ChatSession {
  const user = devUser();
  const source = httpSource({
    baseUrl: "",
    authQuery: () => `dev_user=${encodeURIComponent(user)}`,
  });
  const stores = new Map<ID, ConversationStore>();
  return {
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
