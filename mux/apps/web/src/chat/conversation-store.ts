import type { Conversation, ID, Message, Part, ServerFrame } from "@mux/protocol";
import type { ChatChannel, ChatSource } from "./source.ts";

export interface ConversationState {
  conversation?: Conversation;
  /** My sends not yet echoed by the server, by client id. */
  pending: { clientId: string; message: Message }[];
  typing: ID[];
  connected: boolean;
}

export const EMPTY: ConversationState = { pending: [], typing: [], connected: false };

/** Pure reducer for server frames; the store and tests share it. */
export function applyFrame(state: ConversationState, frame: ServerFrame): ConversationState {
  switch (frame.type) {
    case "snapshot":
      return { ...state, conversation: frame.conversation, connected: true };
    case "message": {
      if (!state.conversation) return state;
      if (state.conversation.messages.some((m) => m.id === frame.message.id)) return state;
      return {
        ...state,
        conversation: {
          ...state.conversation,
          messages: [...state.conversation.messages, frame.message],
        },
        pending: state.pending.filter((p) => p.clientId !== frame.clientId),
        typing: state.typing.filter((id) => id !== frame.message.senderId),
      };
    }
    case "typing": {
      const others = state.typing.filter((id) => id !== frame.participantId);
      return { ...state, typing: frame.on ? [...others, frame.participantId] : others };
    }
    case "participants":
      return state.conversation
        ? { ...state, conversation: { ...state.conversation, participants: frame.participants } }
        : state;
    case "status":
    case "error":
      return state;
  }
}

/**
 * Live state of one conversation for useSyncExternalStore. The socket opens
 * with the first subscriber, closes with the last, and reopens after a drop
 * while anyone is still subscribed.
 */
export class ConversationStore {
  private state: ConversationState = EMPTY;
  private listeners = new Set<() => void>();
  private channel?: ChatChannel;
  private readonly source: ChatSource;
  private readonly id: ID;
  private readonly viewerId: ID;
  private readonly onMessage: () => void;

  /** `onMessage` runs after each new message, e.g. to refresh conversation lists. */
  constructor(source: ChatSource, id: ID, viewerId: ID, onMessage: () => void = () => {}) {
    this.source = source;
    this.id = id;
    this.viewerId = viewerId;
    this.onMessage = onMessage;
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (!this.channel) this.open();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) {
        const channel = this.channel;
        this.channel = undefined;
        channel?.close();
      }
    };
  };

  getSnapshot = (): ConversationState => this.state;

  send(parts: Part[]): void {
    const clientId = crypto.randomUUID();
    const message: Message = {
      id: `pending-${clientId}`,
      senderId: this.viewerId,
      sentAt: new Date().toISOString(),
      parts,
      reactions: [],
      status: { state: "sending" },
    };
    this.set({ ...this.state, pending: [...this.state.pending, { clientId, message }] });
    this.channel?.send({ type: "send", clientId, parts });
  }

  private open(): void {
    const channel = this.source.connect(
      this.id,
      (frame) => {
        this.set(applyFrame(this.state, frame));
        if (frame.type === "message") this.onMessage();
      },
      () => {
        if (this.channel !== channel) return;
        this.channel = undefined;
        this.set({ ...this.state, connected: false });
        if (this.listeners.size > 0) this.open();
      },
    );
    this.channel = channel;
  }

  private set(next: ConversationState): void {
    this.state = next;
    for (const listener of this.listeners) listener();
  }
}
