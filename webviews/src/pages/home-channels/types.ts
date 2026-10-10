// Wire types of the `cmux.home.*` page namespace (CmuxNextApp/Pages/HomeChannelsPageProvider.swift).
// The host projects the Home data the native Home reads (HomeSource: the session daemon's local
// conversation owner plus the Cloud owners) into these shapes. The page keeps a window of it as
// view state; it is never a second store. Times are milliseconds since 1970.

export const HomeOps = {
  inbox: "cmux.home.inbox",
  page: "cmux.home.page",
  history: "cmux.home.history",
  send: "cmux.home.send",
  read: "cmux.home.read",
  react: "cmux.home.react",
  search: "cmux.home.search",
  events: "cmux.home.events",
} as const;

export type ParticipantKind = "human" | "agent";

export interface HomeParticipant {
  id: string;
  kind: ParticipantKind;
  name: string;
  /** A Chief (the user's own agent that runs the others). */
  chief: boolean;
}

/** chief and direct: one other participant; group: three or more, or several Chiefs. */
export type ConversationKind = "chief" | "direct" | "group";

export interface HomeConversation {
  id: string;
  owner: "local" | "cloud";
  title: string;
  kind: ConversationKind;
  participants: HomeParticipant[];
  lastSeq: number;
  rev: number;
  updatedAt: number;
  /** Messages after my read cursor. */
  unread: number;
  /** Mentions of me after my read cursor (the owner's count; 0 where the owner keeps none). */
  mentions: number;
  muted: boolean;
  pinned: boolean;
  lastText?: string;
}

export interface HomeMention {
  /** UTF-16 offset into `text`. */
  start: number;
  length: number;
  participant: string;
}

export type HomePart =
  | { type: "text"; text: string; mentions: HomeMention[] }
  | { type: "work"; title: string; status: "running" | "waiting" | "done" | "failed"; preview?: string }
  | { type: "attachment"; name: string; mimeType: string; byteCount: number; hash: string }
  | { type: "other"; text: string };

export interface HomeReaction {
  author: string;
  partIndex: number;
  /** An emoji, or a tapback name (love, like, ...). */
  value: string;
}

export interface HomeMessage {
  id: string;
  conversation: string;
  seq: number;
  author: string;
  createdAt: number;
  editedAt?: number;
  retracted: boolean;
  parts: HomePart[];
  reactions: HomeReaction[];
  /** The message part this one answers (an inline reply). */
  replyTo?: { message: string; partIndex: number };
  /** The first message of the thread this one belongs to (owners that keep threads). */
  threadRoot?: string;
}

export interface HomeInbox {
  me: HomeParticipant;
  conversations: HomeConversation[];
  rev: number;
}

export interface HomePage {
  conversation: HomeConversation;
  messages: HomeMessage[];
}

/** One coalesced batch of owner events: the host sends at most one pending batch at a time. */
export interface HomeEventBatch {
  connection?: "connecting" | "online" | "offline";
  /** The whole inbox changed (first connect, a gap): the page refetches `cmux.home.inbox`. */
  inboxStale?: boolean;
  conversations?: HomeConversation[];
  removed?: string[];
  messages?: HomeMessage[];
  /** Conversations whose open window must be refetched (a gap, a resubscribe). */
  stale?: string[];
  typing?: { conversation: string; participant: string; on: boolean }[];
}

export interface HomeSearchHit {
  conversation: string;
  message: HomeMessage;
}
