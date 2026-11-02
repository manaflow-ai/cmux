// Wire types of the `cmux.home.*` page namespace (CmuxNextApp/Pages/HomeChannelsPageProvider.swift).
// The host projects the Home data the native Home reads (HomeSource: the session daemon's local
// conversation owner plus the Cloud owners) into these shapes. The page keeps a window of it as
// view state; it is never a second store. Times are milliseconds since 1970.

/** The owner's parts per message (cmux-conversation and home-core `MAX_PARTS`): a protocol bound on
 * one message, never on a send. A send with more files goes as several messages
 * (`messageGroups`), so any number of files attaches. cap-allow: route */
export const MESSAGE_PARTS = 16;

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
  resolveLink: "cmux.home.resolveLink",
  updateThread: "cmux.home.updateThread",
  pin: "cmux.home.pin",
  markUnread: "cmux.home.markUnread",
  /** The person views a conversation or stopped (`{conversation, viewing}`): the Cloud owner's
   * viewing presence (`cloud-conversation-presence-v1`). A local conversation, or a daemon
   * without the capability, sends nothing; the answer is `{sent}`. */
  view: "cmux.home.view",
  /** What this host can do with attachments ({local, cloud}); absent op: nothing. */
  attachmentSupport: "cmux.home.attachmentSupport",
  /** One step of an attachment upload (begin, chunk, commit, cancel), the owner's chunked upload. */
  attachmentUpload: "cmux.home.attachmentUpload",
  /** Bytes of one attachment variant, base64 (images: shown as data URLs, any page CSP). */
  attachmentRead: "cmux.home.attachmentRead",
  /** A short-lived URL of one attachment variant (video playback with seeking, downloads). */
  attachmentUrl: "cmux.home.attachmentUrl",
  /** A participant's picture ({participant}): {avatar: {sha256, mediaType, data} | null}. */
  avatar: "cmux.home.avatar",
  runs: "cmux.home.runs",
  run: "cmux.home.run",
  /** The live text of a conversation's running runs ({conversation}): a `run.live` snapshot
   * (HomeLiveSnapshot), or null when it arrives as a live event instead (a Cloud owner). */
  live: "cmux.home.live",
  events: "cmux.home.events",
  /** What this host and its owners let the page do beyond messages (HomeCapabilities). */
  capabilities: "cmux.home.capabilities",
  /** Everyone the page may add to a local conversation: people met so far and the Chiefs. */
  directory: "cmux.home.directory",
  /** Opens my direct message with one participant, or makes a new conversation; `{conversation}`. */
  startConversation: "cmux.home.startConversation",
  /** Adds participants to a local conversation (`participants.add`). */
  invite: "cmux.home.invite",
  /** The Chief records (`chief.profile.list`). */
  chiefs: "cmux.home.chiefs",
  /** A Chief's name and role (the rest needs the person's gesture in the app: the host). */
  chiefUpdate: "cmux.home.chiefUpdate",
  chiefAvatarSet: "cmux.home.chiefAvatarSet",
  /** A Chief's picture, base64 (`{mediaType, data}`), or null. */
  chiefAvatar: "cmux.home.chiefAvatar",
} as const;

/** `cmux.home.capabilities`: each entry is hidden when its capability is missing (no dead ends). */
export interface HomeCapabilities {
  /** New message and channel (`conversation-create` on the local owner). */
  start: boolean;
  /** Add people or Chiefs to a local conversation (`participants.add`). */
  invite: boolean;
  /** Create Chiefs and edit their profile and picture (`chief-profile-ws-v1`). */
  chiefs: boolean;
}

/** The tools a Chief may be granted (the daemon's closed catalog). */
export const CHIEF_TOOLS = ["spawn", "tell", "workspaces", "browser", "cloud_vms", "chiefs", "memory_import"] as const;
/** A new Chief's tools when the person names none (the daemon's default). */
export const DEFAULT_CHIEF_TOOLS = ["spawn", "tell", "workspaces", "chiefs"] as const;
/** The agent harnesses a Chief's subagents may use (none checked: every harness). */
export const CHIEF_HARNESSES = ["claude", "codex", "opencode", "pi"] as const;

/** The official engines a Chief's own brain runs on (its record's `engine.harness`). The first is
 * the default: a record that names none, or "default", runs on it. Not the subagent grant above. */
export const CHIEF_BACKENDS = [
  { id: "claude", label: "chief.backend.claude" },
  { id: "codex", label: "chief.backend.codex" },
  { id: "unii", label: "chief.backend.unii" },
] as const;
export type ChiefBackend = (typeof CHIEF_BACKENDS)[number]["id"];
/** The engine a Chief starts on when the person picks none. */
export const DEFAULT_CHIEF_BACKEND: ChiefBackend = "claude";

/** The engine id a record names, with absent and "default" read as the default engine. */
export function chiefBackend(harness?: string): string {
  const id = harness?.trim().toLowerCase();
  return !id || id === "default" ? DEFAULT_CHIEF_BACKEND : id;
}

/** A Chief engine's display name ("Claude", "Codex", "UniiChat"); an unknown id shows as it is. */
export function chiefBackendLabel(t: (key: string) => string, harness?: string): string {
  const id = chiefBackend(harness);
  const known = CHIEF_BACKENDS.find((backend) => backend.id === id);
  return known ? t(known.label) : (harness?.trim() ?? id);
}

/** The engine chip a Chief's row shows: only when it runs on something other than the default. */
export function chiefBackendChip(t: (key: string) => string, chief: HomeChief | undefined): string | undefined {
  if (!chief || chiefBackend(chief.engine?.harness) === DEFAULT_CHIEF_BACKEND) return undefined;
  return chiefBackendLabel(t, chief.engine?.harness);
}

/** A Chief record (`chief.profile.*`). */
export interface HomeChief {
  id: string;
  name: string;
  role: string;
  personality: string;
  instructions: string;
  tools: string[];
  harnesses: string[];
  selfEdit: string[];
  isDefault: boolean;
  rev: number;
  /** When the owner made the record (two owners' records differ by it). */
  createdAt: string;
  /** The picture's hash (the page reads its bytes once per hash). */
  avatar?: string;
  /** The Chief's backend, the engine its brain runs on (the record's `engine`): an acpmux harness
   * id, its model and effort. Absent fields: the Chief's usual (the owner's default, Claude). The
   * Chief editor changes it (`chief.profile.update`, after the harness check passes). */
  engine?: { harness?: string; model?: string; effort?: string };
  /** Only the person may change this Chief (`locked`): every Chief write is refused. */
  locked?: boolean;
}

/** A Chief's backend as the editor picks it: "" means the Chief's usual (the owner's default). */
export interface HomeChiefEngine {
  harness: string;
  model: string;
  effort: string;
}

/** One committed state of a Chief's record (`chief.profile.history`), newest first. */
export interface HomeChiefRevision {
  rev: number;
  /** When it was committed (ISO 8601). */
  at: string;
  /** Who made it: a Chief's id, or empty for the person (terminal or app). */
  actor: string;
  /** The operation that made it (`chief.profile.update`, `chief.profile.undo`, ...). */
  operation: string;
  record: HomeChief;
}

/** An acpmux harness a Chief may run on (`_acpmux/harnesses` with its probed models). */
export interface HomeChiefBackend {
  id: string;
  name: string;
  models: { id: string; name: string; efforts: string[] }[];
  /** Why acpmux will not run it now (a failed launcher check), if it says. */
  unavailable?: string;
}

/** Bring your own backend: an ACP agent command, or an Anthropic- or OpenAI-compatible endpoint.
 * The key goes to the Keychain through the host; the page never keeps it after submit. */
export type HomeChiefByoBackend =
  | { kind: "command"; name: string; command: string; args: string[] }
  | { kind: "anthropic-endpoint" | "openai-endpoint"; name: string; baseUrl: string; model: string; apiKey: string };

/** `_acpmux/harness/doctor {id, prompt: true}`: each step, the first failing one with its fix. */
export interface HomeChiefDoctor {
  ok: boolean;
  steps: { name: string; ok: boolean; detail?: string; fix?: string }[];
}

/** A Chief's profile text as the sheet edits it. */
export interface HomeChiefProfile {
  name: string;
  role: string;
  personality: string;
  instructions: string;
}

/** What a page changes without the person's gesture (`cmux.home.chiefUpdate`). */
export type HomeChiefNames = Pick<HomeChiefProfile, "name" | "role">;

/** A Chief's grant (tools, harnesses): the person changes it only with a click in the cmux app. */
export interface HomeChiefGrant {
  tools: string[];
  harnesses: string[];
}

/** The grant fields the person changed (the others are not sent: the owner keeps its defaults). */
export type HomeChiefGrantChange = Partial<HomeChiefGrant>;

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
  /** Pinned by me (my own list state; the owner keeps it per person). */
  pinned: boolean;
  /** My pin order: lower first (owners with conversation-inbox-state-v1; the pin time in ms). */
  pinPosition?: number;
  /** I marked it unread (the read cursor stays); opening it clears the mark. */
  markedUnread?: boolean;
  lastText?: string;
  /** When the last message was posted (the list's order and time; a read moves `updatedAt`). */
  lastAt?: number;
  /** The last message's author (the list's preview names it in a room). */
  lastAuthor?: string;
  /** The status of the last message's work part, when it has one (a Chief's live state). */
  lastWork?: "running" | "waiting" | "done" | "failed";
  /** A Chief's state as the owner derives it (home-inbox-v1): typing, its runs, its last work. */
  chiefState?: "working" | "waiting" | "idle";
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
  | HomeAttachment
  | { type: "other"; text: string };

/** A derived image of an attachment (a video's poster, an image's preview): JPEG or WebP. */
export interface HomeDerivedImage {
  hash: string;
  mimeType: string;
  byteCount: number;
}

/** An `attachment` part (home-messaging.md section 2): a file the owner stores by SHA-256. */
export interface HomeAttachment {
  type: "attachment";
  hash: string;
  name: string;
  mimeType: string;
  byteCount: number;
  width?: number;
  height?: number;
  durationMs?: number;
  poster?: HomeDerivedImage;
  preview?: HomeDerivedImage;
}

/** `cmux.home.attachmentSupport`: which owners take attachments through this host. */
export interface HomeAttachmentSupport {
  local: boolean;
  cloud: boolean;
}

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
  /** A thread root's object (title, owner, resolution); owners with conversation-thread-objects-v1. */
  thread?: HomeThreadObject;
}

export type HomeThreadStatus = "open" | "resolved";

/** The owner's thread object on a root. A resolution reads as resolved only while no live reply has
 * a seq above `resolved.seq`: a new reply reopens the thread (threadStatus in model.ts). */
export interface HomeThreadObject {
  /** Absent: show the root's first line (threadTitle in model.ts). */
  title?: string;
  /** A participant id: a person or a Chief. */
  owner?: string;
  resolved?: { by: string; at: number; seq: number };
}

/** `cmux.home.updateThread`: any participant sets a thread's title, status or owner. An empty
 * title or owner clears it; at least one field. The owner sends `thread.update`. */
export interface HomeThreadUpdate {
  conversation: string;
  root: string;
  title?: string;
  status?: HomeThreadStatus;
  owner?: string;
  idempotencyKey?: string;
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
  /** The owner keeps my pins and marks (conversation-inbox-state-v1): the page offers Pin and
   * Mark as Unread only then. */
  inboxState?: boolean;
}

/** `cmux.home.pin`: pin or unpin a conversation in my list (pinned last, by pin time). */
export interface HomePinRequest {
  conversation: string;
  pinned: boolean;
  idempotencyKey?: string;
}

/** `cmux.home.markUnread`: flag a conversation unread, or clear the flag. */
export interface HomeMarkUnreadRequest {
  conversation: string;
  unread: boolean;
  idempotencyKey?: string;
}

/** One change of my own list state of a conversation (a pin, a mark). */
export interface HomeInboxChange {
  conversation: string;
  pinned: boolean;
  pinPosition?: number;
  markedUnread: boolean;
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
  /** The owner's derived status (absent before conversation-thread-objects-v1: open). */
  status?: HomeThreadStatus;
  title?: string;
  owner?: string;
  /** Only while resolved. */
  resolvedBy?: string;
  resolvedAt?: number;
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
  presence?: { conversation: string; participants: { participant: string; viewing: boolean }[] }[];
  /** Presence frames may have been lost (a stream overflow): every viewer set is unknown until the
   * owner's next whole set. */
  presenceLost?: boolean;
  /** Running replies, in order (applied before this batch's messages). */
  drafts?: HomeDraftItem[];
  /** My own list state changes (pins, marks), in order. */
  inbox?: HomeInboxChange[];
  /** Agent runs that changed: each run after the change and the steps it wrote. */
  runs?: HomeRunChange[];
  /** Participants whose picture changed (`participant-avatar-changed`). */
  avatars?: string[];
  /** A Chief's live run frames (`chief-live-v1`), in order: never stored by any owner. */
  live?: HomeLiveFrame[];
}

/** One live frame of a running run (the "Live frames" contract both brains send). */
export type HomeLiveFrame =
  | {
      type: "step.delta";
      conversation: string;
      run: string;
      /** The run's agent (the owner stamps it; run ids repeat across Cloud Chiefs). */
      author?: string;
      step: string;
      kind: "talk" | "thought";
      /** Per (run, step), from 0, +1 per frame. */
      seq: number;
      text: string;
      /** The step's last frame: its row with the whole text follows on the run. */
      final?: true;
    }
  | {
      type: "run.activity";
      conversation: string;
      run: string;
      author?: string;
      line: string;
      since: number;
      at: number;
    }
  | HomeLiveSnapshot;

/** The text so far of a conversation's running runs (`run.live`): on join, reconnect and gap. */
export interface HomeLiveSnapshot {
  type: "run.live";
  conversation: string;
  runs: {
    run: string;
    author?: string;
    steps: { step: string; kind: "talk" | "thought"; seq: number; text: string; final?: true }[];
    activity?: { line: string; since: number; at: number };
  }[];
}

export interface HomeSearchHit {
  conversation: string;
  message: HomeMessage;
}

/** `cmux.home.resolveLink`: what a conversation or message link opens (the daemon's
 * `conversation-link-resolve`). `path` runs from the thread root down to the message. */
export interface HomeResolvedLink {
  conversation: string;
  message?: HomeMessage;
  threadRoot?: string;
  path: string[];
}

export type HomeRunStatus = "running" | "done" | "failed" | "cancelled";
export type HomeRunStepKind = "talk" | "thought" | "tool" | "note";

/** A file a tool call changed or read: texts when they were small enough to keep. */
export interface HomeRunFile {
  path: string;
  oldText?: string;
  newText?: string;
  added?: number;
  removed?: number;
  line?: number;
}

/** A picture or recording a step made: an attachment record of the conversation. */
export interface HomeRunAttachment {
  hash: string;
  name: string;
  mimeType: string;
  byteCount: number;
  width?: number;
  height?: number;
  durationMs?: number;
}

/** One step of an agent run (`conversation-runs-v1`): a reply segment, a thought summary, a tool
 * call with its input and output, or a note. `seq` is its place; `rev` grows with each write. */
export interface HomeRunStep {
  id: string;
  seq: number;
  at: number;
  rev: number;
  kind: HomeRunStepKind;
  status?: "running" | "done" | "failed";
  text?: string;
  truncated?: boolean;
  tool?: {
    name: string;
    kind?: string;
    title?: string;
    input?: unknown;
    output?: string;
    outputTruncated?: boolean;
    exitCode?: number;
    startedAt?: number;
    endedAt?: number;
    files: HomeRunFile[];
  };
  attachments: HomeRunAttachment[];
  links: { label: string; url: string }[];
}

/** An agent run: the trajectory of one agent turn. `turn` is the `clientMessageId` of the reply the
 * run ends with, so the run shows on that reply; a running run with no reply shows as live work. */
export interface HomeRun {
  id: string;
  conversation: string;
  author: string;
  status: HomeRunStatus;
  startedAt: number;
  endedAt?: number;
  updatedAt: number;
  rev: number;
  stepCount: number;
  turn?: string;
  answers: string[];
  threadRoot?: string;
  title?: string;
  usage?: { input?: number; output?: number; cacheRead?: number; cacheWrite?: number };
  costUsd?: number;
  model?: string;
  harness?: string;
  error?: string;
  session?: { kind: string; id: string; host?: string };
  workspace?: string;
}

export interface HomeRunChange {
  run: HomeRun;
  steps: HomeRunStep[];
}

/** `cmux.home.runs`: runs of these reply keys, or a page of newest runs before `beforeStartedAt`. */
export interface HomeRunList {
  runs: HomeRun[];
  hasMore: boolean;
  /** This owner returned every retained run answering the requested message ids. */
  answersComplete?: boolean;
}

/** `cmux.home.run`: one run and its steps written after `afterRev`, oldest write first. */
export interface HomeRunPage {
  run: HomeRun;
  steps: HomeRunStep[];
  hasMore: boolean;
}
