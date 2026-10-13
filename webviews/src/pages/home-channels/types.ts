// Wire types of the `cmux.home.*` page namespace (CmuxNextApp/Pages/HomeChannelsPageProvider.swift).
// The host projects the Home data the native Home reads (HomeSource: the session daemon's local
// conversation owner plus the Cloud owners) into these shapes. The page keeps a window of it as
// view state; it is never a second store. Times are milliseconds since 1970.

export const HomeOps = {
  inbox: "cmux.home.inbox",
  page: "cmux.home.page",
  history: "cmux.home.history",
  thread: "cmux.home.thread",
  send: "cmux.home.send",
  read: "cmux.home.read",
  react: "cmux.home.react",
  search: "cmux.home.search",
  edit: "cmux.home.edit",
  retract: "cmux.home.retract",
  createGroup: "cmux.home.createGroup",
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
  /** When the conversation was created (hosts that send it; else updatedAt stands in). */
  createdAt?: number;
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
  /** The emoji shown (a tapback shows its emoji). */
  value: string;
  /** The tapback name (love, like, ...) when the reaction is a tapback; sent back to take it back. */
  tapback?: string;
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
  /** The author's idempotency key: an agent's reply carries its turn's key, so its draft ends. */
  clientMessageId?: string;
}

/** One item of an agent's running reply (`conversation-draft`, ephemeral, never stored). A `fresh`
 * item sets its segment's whole text; another appends when its seq follows the last; `done` ends
 * the turn. `turn` is the idempotency key the posted reply will carry. Only `talk` text shows. */
export interface HomeDraftItem {
  conversation: string;
  participant: string;
  turn: string;
  segment: number;
  seq: number;
  talk: boolean;
  text: string;
  fresh: boolean;
  done: boolean;
}

export interface HomeInbox {
  me: HomeParticipant;
  conversations: HomeConversation[];
  rev: number;
}

/** The owner's stats of one thread root, counted over every reply (not only the loaded window).
 * A retracted reply still counts. Hosts before conversation-thread-v1 send none. */
export interface HomeThreadStats {
  root: string;
  replyCount: number;
  /** The newest reply's seq (absent with no reply): a loaded reply after it is not counted yet. */
  lastReplySeq?: number;
  lastReplyAt?: number;
  /** The first three distinct reply authors. */
  authors: string[];
}

export interface HomePage {
  conversation: HomeConversation;
  messages: HomeMessage[];
  /** Stats of the thread roots in `messages`. */
  threads?: HomeThreadStats[];
}

/** `cmux.home.history`: one older page. */
export interface HomeHistory {
  messages: HomeMessage[];
  threads?: HomeThreadStats[];
}

/** `cmux.home.thread`: the root, the replies after `afterSeq` (ascending) and the thread's stats. */
export interface HomeThreadPage {
  root: HomeMessage;
  replies: HomeMessage[];
  hasMore: boolean;
  thread: HomeThreadStats;
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
  /** Running replies, in order (applied before this batch's messages). */
  drafts?: HomeDraftItem[];
}

export interface HomeSearchHit {
  conversation: string;
  message: HomeMessage;
}
