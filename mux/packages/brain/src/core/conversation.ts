// The local conversation owner's wire types (plans/cmux-next/home.md section 2).

export type ParticipantId = string;
export const USER_LOCAL: ParticipantId = "user_local";
export const AGENT_MUX: ParticipantId = "agent_mux";
export const LOCAL_CONVERSATIONS_CAPABILITY = "local-conversations-v1";

export interface Participant {
  id: ParticipantId;
  kind: "human" | "agent";
  display_name: string;
  agent_class?: "mux" | "agent";
  acp_session?: string;
  /** The person a `remote_<install>` device belongs to (`user_local`). */
  person?: ParticipantId;
}

export interface PartRef {
  message_id: string;
  part_index: number;
}

export interface TextRun {
  start: number;
  length: number;
  mention?: ParticipantId;
  link?: string;
}

export type WorkStatus = "running" | "done" | "failed" | "waiting";

export type Part =
  | { type: "text"; text: string; runs?: TextRun[] }
  | { type: "work"; session: string; host?: string; status: WorkStatus; preview?: string };

export type ReactionKind =
  | { tapback: "love" | "like" | "dislike" | "laugh" | "emphasize" | "question" }
  | { emoji: string };

export interface Reaction {
  author: ParticipantId;
  part_index: number;
  kind: ReactionKind;
  at: string;
}

/** Where a message came from; absent for local messages. */
export interface Origin {
  kind: "remote";
  install: string;
}

export interface Message {
  id: string;
  conversation: string;
  seq: number;
  client_msg_id: string;
  author: ParticipantId;
  parts: Part[];
  reply_to?: PartRef;
  created_at: string;
  edited_at?: string;
  retracted_at?: string;
  reactions: Reaction[];
  /** Where it came from (stamped by the owner); absent for local messages. */
  origin?: Origin;
}

export interface Summary {
  id: string;
  owner: "local";
  title: string;
  participants: Participant[];
  last_seq: number;
  rev: number;
  created_at: string;
  updated_at: string;
  last_message?: Message;
  read_cursors: Record<ParticipantId, number>;
}

export type Op =
  | { kind: "message.send"; client_msg_id: string; parts: Part[]; reply_to?: PartRef }
  | { kind: "message.edit"; message_id: string; parts: Part[] }
  | { kind: "message.retract"; message_id: string }
  | { kind: "reaction.add" | "reaction.remove"; message_id: string; part_index: number; reaction: ReactionKind }
  | { kind: "read_cursor.set"; seq: number }
  | { kind: "participants.add"; participant: Participant }
  | { kind: "title.set"; title: string };

export type Change =
  | { kind: "message"; message: Message }
  | { kind: "message-updated"; message: Message }
  | { kind: "read-cursor"; participant: ParticipantId; seq: number }
  | { kind: "conversation"; conversation: Summary };

export interface OpResult {
  transaction?: string;
  rev: number;
  seq?: number;
  replayed: boolean;
  change: Change;
}

export interface ConversationChangedEvent {
  event: "conversation-changed";
  conversation: string;
  rev: number;
  transaction?: string;
  change: Change;
}

export interface ConversationTypingEvent {
  event: "conversation-typing";
  conversation: string;
  participant: ParticipantId;
  on: boolean;
}

/** The plain text of a message (text parts joined). */
export function messageText(message: Message): string {
  return message.parts
    .map((part) => (part.type === "text" ? part.text : ""))
    .filter(Boolean)
    .join("\n");
}
