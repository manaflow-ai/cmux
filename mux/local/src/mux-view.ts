// The mux session's acpmux event log, folded into one Messages conversation.
// acpmux is the source of truth; this view is derived and rebuilt on start.

import type { Conversation, Message, Participant } from "@mux/protocol";

/** Fixed id: Home shows one conversation, the mux. */
export const MUX_CONVERSATION_ID = "6d757800-0000-4000-8000-000000000001";
export const EVENT_PREFIX = "[mux-event]";

export interface AcpmuxEvent {
  seq: number;
  at: number;
  dir: string;
  kind: string;
  msg: Record<string, unknown>;
}

export interface ViewChange {
  /** Messages to publish (new, or a reply that just completed). */
  messages: Message[];
  /** Typing state changed for the mux. */
  typing?: boolean;
}

export class MuxView {
  readonly participants: Participant[];
  private messages: Message[] = [];
  private reply?: { id: string; text: string; at: number };
  private readonly viewerId: string;
  private readonly muxId: string;
  private readonly agentsId: string;

  constructor(viewer: { id: string; displayName: string }, muxId = "mux", agentsId = "agents") {
    this.viewerId = viewer.id;
    this.muxId = muxId;
    this.agentsId = agentsId;
    this.participants = [
      { kind: "human", id: viewer.id, displayName: viewer.displayName },
      { kind: "mux", id: muxId, displayName: "mux" },
      { kind: "mux", id: agentsId, displayName: "Agents" },
    ];
  }

  conversation(): Conversation {
    return {
      id: MUX_CONVERSATION_ID,
      title: "mux",
      participants: this.participants,
      messages: [...this.messages],
    };
  }

  /** Applies one event; returns what clients need to hear about. */
  apply(event: AcpmuxEvent): ViewChange {
    const sentAt = new Date(event.at || Date.now()).toISOString();
    if (event.dir === "mux" && event.kind === "user_message") {
      const raw = typeof event.msg.text === "string" ? event.msg.text : "";
      const isEvent = raw.startsWith(EVENT_PREFIX);
      const message: Message = {
        id: typeof event.msg.promptId === "string" ? event.msg.promptId : `user-${event.seq}`,
        senderId: isEvent ? this.agentsId : this.viewerId,
        sentAt,
        parts: [{ type: "text", text: isEvent ? eventSummary(raw) : raw }],
        reactions: [],
      };
      return { messages: this.push(message) };
    }
    if (event.dir === "mux" && event.kind === "turn_started") {
      this.reply = { id: `reply-${event.seq}`, text: "", at: event.at };
      return { messages: [], typing: true };
    }
    if (event.kind === "agent_message_chunk") {
      const update = (
        event.msg.params as { update?: { content?: { type?: string; text?: string } } } | undefined
      )?.update;
      if (update?.content?.type === "text" && update.content.text) {
        this.reply ??= { id: `reply-${event.seq}`, text: "", at: event.at };
        this.reply.text += update.content.text;
      }
      return { messages: [] };
    }
    if (event.dir === "mux" && (event.kind === "turn_end" || event.kind === "turn_error")) {
      const reply = this.reply;
      this.reply = undefined;
      const text =
        reply?.text.trim() ||
        (event.kind === "turn_error"
          ? `(turn failed: ${JSON.stringify(event.msg).slice(0, 200)})`
          : "");
      if (!text) return { messages: [], typing: false };
      const message: Message = {
        id: reply?.id ?? `reply-${event.seq}`,
        senderId: this.muxId,
        sentAt,
        parts: [{ type: "text", text }],
        reactions: [],
      };
      return { messages: this.push(message), typing: false };
    }
    return { messages: [] };
  }

  private push(message: Message): Message[] {
    if (this.messages.some((m) => m.id === message.id)) return [];
    this.messages.push(message);
    return [message];
  }
}

/** The first line of a supervisor event, without the instructions meant for the mux. */
function eventSummary(raw: string): string {
  const body = raw.slice(EVENT_PREFIX.length).trim();
  const firstLine = body.split("\n")[0] ?? body;
  const reply = body.match(/Its reply:\n([\s\S]*?)\n\n/);
  return reply ? `${firstLine}\n${reply[1].trim().slice(0, 400)}` : firstLine;
}
