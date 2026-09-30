import type {
  ClientFrame,
  Conversation,
  ConversationSummary,
  CreateConversationRequest,
  ID,
  ServerFrame,
  Viewer,
} from "@mux/protocol";

/**
 * Where the UI reads chats from. The UI depends only on this interface, so the
 * mux worker, a test double and a native bridge are swappable.
 */
export interface ChatSource {
  viewer(): Promise<Viewer>;
  listConversations(): Promise<ConversationSummary[]>;
  createConversation(request: CreateConversationRequest): Promise<Conversation>;
  /** Opens a live channel; frames arrive on `onFrame` until `close`. */
  connect(
    conversationId: ID,
    onFrame: (frame: ServerFrame) => void,
    onClose: () => void,
  ): ChatChannel;
}

export interface ChatChannel {
  send(frame: ClientFrame): void;
  close(): void;
}
