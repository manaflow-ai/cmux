import type { Conversation, ID } from "@mux/protocol";

/**
 * Where the UI reads chats from. The UI depends only on this interface, so the
 * fixture below, the mux worker's WebSocket and a native bridge are swappable.
 */
export interface ChatSource {
  viewerId: ID;
  listConversations(): Promise<ConversationSummary[]>;
  getConversation(id: ID): Promise<Conversation>;
}

export interface ConversationSummary {
  id: ID;
  title: string;
  preview: string;
  lastAt: string;
}
