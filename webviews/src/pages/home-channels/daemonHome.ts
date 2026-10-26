// The `cmux.home.*` page namespace served straight from the cmux instance's daemon over its
// WebSocket (ws-conversations-v1): the local conversation owner's raw `conversation-*` commands and
// `subscribe` events, projected into the page's shapes (types.ts). The same rules the app's Home
// applies (CmuxHomeCore `ConversationSummary.kind` and `unreadCount`, HomeCoreMapping): no Swift in
// the data path, so the page runs the same in a plain browser, the app's web view, Chromium and
// GPUI. Cloud conversations come through the same daemon (cloudHome.ts, ws-cloud-conversations-v1)
// and merge into the one inbox. In the app the local conversations may live on another daemon, this
// build's Chief home's conversation owner (`owner` in `cmux.host.credential.load`): then the local
// `conversation-*` commands and events go to that socket and the Cloud stays on the build daemon.
// Slice 3 moves this projection into the daemon as `home.*` operations.
import { pageError, type PageClient, type PageCallOptions, type PageHandler } from "../shared/pageClient";
import { PAGE_CONNECTION } from "../shared/pageStreams";
import type { DaemonError, DaemonSocket } from "../shared/daemonSocket";
import { CloudHome, WS_CLOUD_CAPABILITY } from "./cloudHome";
import { DaemonPeople } from "./daemonPeople";
import {
  HomeOps,
  type HomeAttachment,
  type HomeChiefNames,
  type HomeConversation,
  type HomeDerivedImage,
  type HomeEventBatch,
  type HomeInboxChange,
  type HomeLiveFrame,
  type HomeLiveSnapshot,
  type HomeMessage,
  type HomeParticipant,
  type HomePart,
  type HomeReaction,
  type HomeResolvedLink,
  type HomeRun,
  type HomeRunStep,
  type HomeThreadObject,
  type HomeThreadStats,
} from "./types";

type Json = Record<string, unknown>;

const LOCAL_USER = "user_local";
/** `thread.update`, `Message.thread` and the thread object fields of the stats. */
const THREAD_OBJECTS_CAPABILITY = "conversation-thread-objects-v1";
/** My own pins and marks: `conversation-inbox-op`, the list fields, `conversation-inbox-changed`
 * and `cloud-inbox-op` (the Cloud owner's `inbox.pin` and `inbox.mark_unread`). */
const INBOX_STATE_CAPABILITY = "conversation-inbox-state-v1";
/** `home-inbox`: the owner derives the list rows (kind, name, unread, preview, a Chief's state, my
 * pins and marks) once for every view; the page shows them instead of projecting summaries. */
const HOME_INBOX_CAPABILITY = "home-inbox-v1";
/** Attachment uploads, reads and download links on this WebSocket (local conversations). */
const WS_ATTACHMENTS_CAPABILITY = "ws-attachments-v1";
/** The same three attachment commands for cloud conversations, through the daemon's lease. */
const CLOUD_ATTACHMENTS_CAPABILITY = "cloud-attachments-v1";
/** The attachment steps the page may send (the owner checks every field). */
const UPLOAD_STEPS = new Set(["begin", "chunk", "commit", "cancel"]);
const CHIEF = { id: "agent_mux", kind: "agent", display_name: "Chief", agent_class: "mux", acp_session: "mux" };
const TAPBACK_EMOJI: Record<string, string> = {
  love: "❤️",
  like: "👍",
  dislike: "👎",
  laugh: "😂",
  emphasize: "‼️",
  question: "❓",
};
const MAX_PAGE = 200;
/** Agent runs (`conversation-run*`, the `conversation-run-changed` event for a page that asks). */
const RUNS_CAPABILITY = "conversation-runs-v1";
/** A Cloud Chief's runs through the daemon (`cloud-conversation-run*`). */
const CLOUD_RUNS_CAPABILITY = "cloud-conversation-runs-v1";
/** A Chief's live run frames (`conversation-live*`, the `conversation-live` event for a page that asks). */
const LIVE_CAPABILITY = "chief-live-v1";
/** A Cloud Chief's live frames through the daemon (`cloud-conversation-live`). */
const CLOUD_LIVE_CAPABILITY = "cloud-chief-live-v1";
/** The daemon passes a cloud conversation's typing (`cloud-conversation-typing`) to a connection that
 *  echoes this. */
const CLOUD_TYPING_CAPABILITY = "cloud-conversation-typing-v1";
/** `cloud-conversation-presence {conversation, viewing}`, and the `cloud-conversation-presence`
 *  event the daemon passes only to a connection that echoes this. */
export const CLOUD_PRESENCE_CAPABILITY = "cloud-conversation-presence-v1";
/** Participants' pictures (`participant.avatar.get`, `cloud-participant-avatar-get`, the
 * `participant-avatar-changed` event for a page that asks). */
const AVATARS_CAPABILITY = "participant-avatars-v1";

const time = (value: unknown): number => (typeof value === "string" ? Date.parse(value) || 0 : 0);
const num = (value: unknown): number => (typeof value === "number" ? value : 0);
const bounded = (value: unknown, fallback: number): number =>
  Math.min(Math.max(typeof value === "number" ? value : fallback, 1), MAX_PAGE);

function participant(raw: Json): HomeParticipant {
  const chief = raw.kind === "agent" && raw.agent_class === "mux";
  return {
    id: String(raw.id),
    kind: raw.kind === "agent" ? "agent" : "human",
    // Several Chiefs keep their own names; one without a name is "Chief".
    name: String(raw.display_name || (chief ? "Chief" : raw.id)),
    chief,
  };
}

function part(raw: Json): HomePart {
  switch (raw.type) {
    case "text": {
      const runs = (raw.runs as Json[] | undefined) ?? [];
      return {
        type: "text",
        text: String(raw.text ?? ""),
        mentions: runs
          .filter((run) => typeof run.mention === "string")
          .map((run) => ({ start: num(run.start), length: num(run.length), participant: String(run.mention) })),
      };
    }
    case "work": {
      const status = ["running", "waiting", "done", "failed"].includes(String(raw.status)) ? raw.status : "running";
      return {
        type: "work",
        title: String(raw.session ?? ""),
        status: status as "running",
        preview: raw.preview as string | undefined,
      };
    }
    case "attachment":
      return attachmentPart(raw);
    case "link_preview":
      return { type: "other", text: String(raw.url ?? "") };
    default:
      return { type: "other", text: String(raw.type ?? "") };
  }
}

function derivedImage(raw: unknown): HomeDerivedImage | undefined {
  if (!raw || typeof raw !== "object") return undefined;
  const image = raw as Json;
  return { hash: String(image.hash ?? ""), mimeType: String(image.mime_type ?? ""), byteCount: num(image.byte_count) };
}

function attachmentPart(raw: Json): HomeAttachment {
  const part: HomeAttachment = {
    type: "attachment",
    name: String(raw.name ?? ""),
    mimeType: String(raw.mime_type ?? ""),
    byteCount: num(raw.byte_count),
    hash: String(raw.hash ?? ""),
  };
  if (typeof raw.width === "number") part.width = raw.width;
  if (typeof raw.height === "number") part.height = raw.height;
  if (typeof raw.duration_ms === "number") part.durationMs = raw.duration_ms;
  const poster = derivedImage(raw.poster);
  if (poster) part.poster = poster;
  const preview = derivedImage(raw.preview);
  if (preview) part.preview = preview;
  return part;
}

/** The owner's wire form of an attachment part the page sends. */
function wireAttachment(value: unknown): Json {
  if (!value || typeof value !== "object") throw pageError("cmux.page.invalid_params", "attachments");
  const part = value as HomeAttachment;
  const image = (derived: HomeDerivedImage) => ({
    hash: String(derived.hash),
    mime_type: String(derived.mimeType),
    byte_count: num(derived.byteCount),
  });
  const wire: Json = {
    type: "attachment",
    hash: String(part.hash),
    name: String(part.name),
    mime_type: String(part.mimeType),
    byte_count: num(part.byteCount),
  };
  if (typeof part.width === "number") wire.width = part.width;
  if (typeof part.height === "number") wire.height = part.height;
  if (typeof part.durationMs === "number") wire.duration_ms = part.durationMs;
  if (part.poster) wire.poster = image(part.poster);
  if (part.preview) wire.preview = image(part.preview);
  return wire;
}

function reaction(raw: Json): HomeReaction {
  const kind = (raw.kind ?? {}) as { tapback?: string; emoji?: string };
  const base = { author: String(raw.author), partIndex: num(raw.part_index) };
  if (kind.tapback) return { ...base, value: TAPBACK_EMOJI[kind.tapback] ?? kind.tapback, tapback: kind.tapback };
  return { ...base, value: String(kind.emoji ?? "") };
}

export function message(raw: Json): HomeMessage {
  const retracted = typeof raw.retracted_at === "string";
  const replyTo = raw.reply_to as { message_id: string; part_index: number } | undefined;
  const result: HomeMessage = {
    id: String(raw.id),
    conversation: String(raw.conversation),
    seq: num(raw.seq),
    author: String(raw.author),
    createdAt: time(raw.created_at),
    retracted,
    parts: retracted ? [] : ((raw.parts as Json[] | undefined) ?? []).map(part),
    reactions: ((raw.reactions as Json[] | undefined) ?? []).map(reaction),
    clientMessageId: String(raw.client_msg_id ?? ""),
  };
  if (raw.edited_at) result.editedAt = time(raw.edited_at);
  const thread = raw.thread as Json | undefined;
  if (thread && typeof thread === "object") {
    const object: HomeThreadObject = {};
    if (typeof thread.title === "string") object.title = thread.title;
    if (typeof thread.owner === "string") object.owner = thread.owner;
    const resolved = thread.resolved as Json | undefined;
    if (resolved && typeof resolved === "object")
      object.resolved = { by: String(resolved.by), at: time(resolved.at), seq: num(resolved.seq) };
    result.thread = object;
  }
  if (replyTo) result.replyTo = { message: replyTo.message_id, partIndex: replyTo.part_index };
  // A message from before threads marked its thread as a reply to the root (HomeCoreMapping).
  const root = (raw.thread_root as string | undefined) ?? replyTo?.message_id;
  if (root) result.threadRoot = root;
  return result;
}

const opt = <T>(value: T | undefined | null): T | undefined => (value === null ? undefined : value);
const optNum = (value: unknown): number | undefined => (typeof value === "number" ? value : undefined);
const optStr = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);

/** A run as the owner sends it (`conversation-runs-v1`, snake_case), in the page's shape. */
export function run(raw: Json): HomeRun {
  const status = ["running", "done", "failed", "cancelled"].includes(String(raw.status)) ? raw.status : "running";
  const usage = raw.usage as Json | undefined;
  const session = raw.session as Json | undefined;
  const result: HomeRun = {
    id: String(raw.id),
    conversation: String(raw.conversation),
    author: String(raw.author),
    status: status as HomeRun["status"],
    startedAt: num(raw.started_at),
    // 0 when the owner does not say (a Cloud brain's runs): never read as stalled.
    updatedAt: num(raw.updated_at),
    rev: num(raw.rev),
    stepCount: num(raw.step_count),
    answers: ((raw.answers as unknown[] | undefined) ?? []).map(String),
  };
  if (typeof raw.ended_at === "number") result.endedAt = raw.ended_at;
  for (const [from, to] of [
    ["turn", "turn"],
    ["thread_root", "threadRoot"],
    ["title", "title"],
    ["model", "model"],
    ["harness", "harness"],
    ["error", "error"],
    ["workspace", "workspace"],
  ] as const) {
    const value = optStr(raw[from]);
    if (value !== undefined) result[to] = value;
  }
  if (typeof raw.cost_usd === "number") result.costUsd = raw.cost_usd;
  if (usage && typeof usage === "object")
    result.usage = {
      input: optNum(usage.input),
      output: optNum(usage.output),
      cacheRead: optNum(usage.cache_read),
      cacheWrite: optNum(usage.cache_write),
    };
  if (session && typeof session === "object")
    result.session = { kind: String(session.kind), id: String(session.id), host: opt(optStr(session.host)) };
  return result;
}

const liveKind = (value: unknown): "talk" | "thought" | undefined =>
  value === "talk" || value === "thought" ? value : undefined;

/** A live frame (`chief-live-v1`) as the page reads it; undefined for one it does not know. */
export function liveFrame(raw: Json): HomeLiveFrame | undefined {
  const conversation = optStr(raw.conversation);
  if (!conversation) return undefined;
  if (raw.type === "run.live") return liveSnapshot(raw);
  const run = optStr(raw.run);
  if (!run) return undefined;
  if (raw.type === "step.delta") {
    const kind = liveKind(raw.kind);
    const step = optStr(raw.step);
    const text = optStr(raw.text);
    if (!kind || !step || text === undefined || typeof raw.seq !== "number") return undefined;
    const frame: HomeLiveFrame = { type: "step.delta", conversation, run, step, kind, seq: raw.seq, text };
    if (raw.final === true) frame.final = true;
    if (typeof raw.author === "string") frame.author = raw.author;
    return frame;
  }
  if (raw.type === "run.activity" && typeof raw.line === "string") {
    const frame: HomeLiveFrame = {
      type: "run.activity",
      conversation,
      run,
      line: raw.line,
      since: num(raw.since),
      at: num(raw.at),
    };
    if (typeof raw.author === "string") frame.author = raw.author;
    return frame;
  }
  return undefined;
}

/** A `run.live` snapshot as the page reads it. */
export function liveSnapshot(raw: Json): HomeLiveSnapshot | undefined {
  const conversation = optStr(raw.conversation);
  if (raw.type !== "run.live" || !conversation) return undefined;
  const runs: HomeLiveSnapshot["runs"] = [];
  for (const item of (raw.runs as Json[] | undefined) ?? []) {
    if (typeof item?.run !== "string") continue;
    const steps: HomeLiveSnapshot["runs"][number]["steps"] = [];
    for (const step of (item.steps as Json[] | undefined) ?? []) {
      const kind = liveKind(step?.kind);
      if (kind && typeof step.step === "string" && typeof step.text === "string")
        steps.push({
          step: step.step,
          kind,
          seq: num(step.seq),
          text: step.text,
          ...(step.final === true ? { final: true as const } : {}),
        });
    }
    const activity = item.activity as Json | undefined;
    runs.push({
      run: item.run,
      author: optStr(item.author),
      steps,
      activity:
        activity && typeof activity.line === "string"
          ? { line: activity.line, since: num(activity.since), at: num(activity.at) }
          : undefined,
    });
  }
  return { type: "run.live", conversation, runs };
}

/** A run step as the owner sends it, in the page's shape. */
export function runStep(raw: Json): HomeRunStep {
  const kind = ["talk", "thought", "tool", "note"].includes(String(raw.kind)) ? raw.kind : "note";
  const status = ["running", "done", "failed"].includes(String(raw.status)) ? raw.status : undefined;
  const tool = raw.tool as Json | undefined;
  const result: HomeRunStep = {
    id: String(raw.id),
    seq: num(raw.seq),
    at: num(raw.at),
    rev: num(raw.rev),
    kind: kind as HomeRunStep["kind"],
    attachments: ((raw.attachments as Json[] | undefined) ?? []).map((item) => ({
      hash: String(item.hash ?? ""),
      name: String(item.name ?? ""),
      mimeType: String(item.mime_type ?? ""),
      byteCount: num(item.byte_count),
      width: optNum(item.width),
      height: optNum(item.height),
      durationMs: optNum(item.duration_ms),
    })),
    links: ((raw.links as Json[] | undefined) ?? []).map((link) => ({
      label: String(link.label ?? ""),
      url: String(link.url ?? ""),
    })),
  };
  if (status) result.status = status as HomeRunStep["status"];
  if (typeof raw.text === "string") result.text = raw.text;
  if (raw.truncated === true) result.truncated = true;
  if (tool && typeof tool === "object") {
    result.tool = {
      name: String(tool.name ?? "tool"),
      kind: optStr(tool.kind),
      title: optStr(tool.title),
      input: tool.input,
      output: optStr(tool.output),
      outputTruncated: tool.output_truncated === true || undefined,
      exitCode: optNum(tool.exit_code),
      startedAt: optNum(tool.started_at),
      endedAt: optNum(tool.ended_at),
      files: ((tool.files as Json[] | undefined) ?? []).map((file) => ({
        path: String(file.path ?? ""),
        oldText: optStr(file.old_text),
        newText: optStr(file.new_text),
        added: optNum(file.added),
        removed: optNum(file.removed),
        line: optNum(file.line),
      })),
    };
  }
  return result;
}

function plain(raw: Json | undefined): string | undefined {
  if (!raw || raw.retracted_at) return undefined;
  const parts = (raw.parts as Json[] | undefined) ?? [];
  const text = parts
    .map((item) => (item.type === "text" ? String(item.text ?? "") : ""))
    .join(" ")
    .trim();
  // A message of files only previews their names (the page has no wording here).
  const files = parts.filter((item) => item.type === "attachment").map((item) => String(item.name ?? ""));
  return (text || files.join(", ")).slice(0, 200);
}

export function conversation(raw: Json, me: string): HomeConversation {
  const participants = ((raw.participants as Json[] | undefined) ?? []).map(participant);
  const others = participants.filter((entry) => entry.id !== me);
  const kind = others.length === 1 ? (others[0].chief ? "chief" : "direct") : "group";
  const cursors = (raw.read_cursors ?? {}) as Record<string, number>;
  const last = raw.last_message as Json | undefined;
  let cursor = cursors[me] ?? 0;
  if (last && last.author === me) cursor = Math.max(cursor, num(last.seq));
  const lastSeq = num(raw.last_seq);
  const result: HomeConversation = {
    id: String(raw.id),
    owner: raw.owner === "cloud" ? "cloud" : "local",
    title: String(raw.title ?? ""),
    kind,
    participants,
    lastSeq,
    rev: num(raw.rev),
    updatedAt: time(raw.updated_at),
    createdAt: time(raw.created_at),
    unread: lastSeq > cursor ? lastSeq - cursor : 0,
    mentions: 0,
    muted: false,
    // My own list state (conversation-inbox-state-v1: `conversation-list` adds it for me).
    pinned: raw.pinned === true,
  };
  if (result.pinned && typeof raw.pin_position === "number") result.pinPosition = raw.pin_position;
  if (raw.marked_unread === true) result.markedUnread = true;
  const text = plain(last);
  if (text !== undefined) result.lastText = text;
  // The last message's time orders the list even when it was deleted (a read never moves a row).
  if (last) result.lastAt = time(last.created_at);
  if (last && !last.retracted_at) {
    result.lastAuthor = String(last.author);
    const work = ((last.parts as Json[] | undefined) ?? []).find((item) => item.type === "work");
    const status = work && String(work.status);
    if (status === "running" || status === "waiting" || status === "done" || status === "failed")
      result.lastWork = status;
  }
  return result;
}

/** A local row with the facts only the owner knows (`home-inbox`): the kind (a registry Chief, a
 * later room with one person), the Chief's current name and its state (its typing and runs in
 * every conversation, not only the open one). Unread, preview and times stay the page's own: the
 * same rule, and fresher between two row reads. */
export function withHomeRow(row: HomeConversation, owned: Json): HomeConversation {
  const kind = owned.kind === "chief" ? "chief" : owned.kind === "direct" ? "direct" : "group";
  const result: HomeConversation = { ...row, kind };
  if (kind === "chief" && typeof owned.chief === "string") {
    const chief = owned.chief;
    // The Chief participant (a registry Chief may have no agent class).
    result.participants = row.participants.map((p) => (p.id === chief ? { ...p, chief: true } : p));
    if (typeof owned.name === "string" && owned.name) result.title = owned.name;
  }
  const state = owned.chief_state;
  if (state === "working" || state === "waiting" || state === "idle") result.chiefState = state;
  return result;
}

function threads(raw: unknown): HomeThreadStats[] {
  return ((raw as Json[] | undefined) ?? []).map((entry) => {
    const stats: HomeThreadStats = {
      root: String(entry.root),
      replyCount: num(entry.reply_count),
      authors: ((entry.authors as string[] | undefined) ?? []).map(String),
    };
    if (typeof entry.last_reply_seq === "number") stats.lastReplySeq = entry.last_reply_seq;
    if (entry.last_reply_at) stats.lastReplyAt = time(entry.last_reply_at);
    if (entry.status === "open" || entry.status === "resolved") stats.status = entry.status;
    if (typeof entry.title === "string") stats.title = entry.title;
    if (typeof entry.owner === "string") stats.owner = entry.owner;
    if (typeof entry.resolved_by === "string") stats.resolvedBy = entry.resolved_by;
    if (entry.resolved_at) stats.resolvedAt = time(entry.resolved_at);
    return stats;
  });
}

/** A Chief's name and role from a request (the daemon checks every limit). */
function chiefNames(params: Json): HomeChiefNames {
  const text = (field: string, max: number) => {
    const value = params[field];
    if (typeof value !== "string" || value.length > max) throw pageError("cmux.page.invalid_params", field);
    return value;
  };
  return { name: text("name", 100), role: text("role", 200) };
}

function str(params: Json, field: string, max = 256): string {
  const value = params[field];
  if (typeof value !== "string" || !value || value.length > max) throw pageError("cmux.page.invalid_params", field);
  return value;
}

/** Serves the page namespace from the daemon; one instance per page. */
export class DaemonHomeClient implements PageClient {
  private me = LOCAL_USER;
  private nextKey = 1;
  /** The one daemon `subscribe` stream of each connection; page subscriptions share it. */
  private readonly streamStarted = new Map<DaemonSocket, Promise<void>>();
  /** Conversations whose page the page read (refetched after a lost event). */
  private readonly opened = new Set<string>();
  /** The cloud owners through this daemon (when `identify` names the capability). */
  private readonly cloud: CloudHome;
  /** Uploads that `begin` opened through the cloud lease (their later steps go there too). */
  private readonly cloudUploads = new Set<string>();
  /** Each socket's `identify` capabilities, read once. */
  private readonly capabilities = new Map<DaemonSocket, Promise<string[]>>();
  /** The local conversation owner: the build daemon itself, or the Chief home's owner. */
  private readonly local: DaemonSocket;
  /** The connections this client streams from (one, or the build daemon and the local owner). */
  private readonly sockets: DaemonSocket[];
  /** My own list state of each local conversation (pins, marks), from `conversation-list` and
   * `conversation-inbox-changed`: a snapshot or a conversation change carries none, so a summary
   * from them keeps what the list said. */
  private readonly listState = new Map<string, Json>();
  /** The owner's last `home-inbox` rows by conversation id (home-inbox-v1). */
  private readonly homeRows = new Map<string, Json>();
  /** Cloud summaries the hydration read after the inbox answered (sent on the events stream). */
  private readonly cloudListeners = new Set<(conversation: HomeConversation) => void>();
  /** Cloud participants a head named for the first time: their pictures are asked again. */
  private readonly peopleListeners = new Set<(participants: string[]) => void>();

  /** Starts each connection's daemon stream once (a page resubscribe adds a listener only). */
  private startStream(): Promise<void> {
    return Promise.all(this.sockets.map((socket) => this.startSocketStream(socket))).then(() => undefined);
  }

  private startSocketStream(socket: DaemonSocket): Promise<void> {
    let started = this.streamStarted.get(socket);
    if (!started) {
      started = (async () => {
        await socket.request("set-client-info", {
          name: "cmux page: home-channels",
          capabilities: [
            "conversation-draft-events-v1",
            RUNS_CAPABILITY,
            AVATARS_CAPABILITY,
            LIVE_CAPABILITY,
            CLOUD_TYPING_CAPABILITY,
            CLOUD_PRESENCE_CAPABILITY,
          ],
        });
        await socket.request("subscribe");
      })().catch((error) => {
        this.streamStarted.delete(socket);
        throw error;
      });
      this.streamStarted.set(socket, started);
    }
    return started;
  }

  /** `daemon`: the build daemon (Cloud, and local conversations unless `local` is given). */
  constructor(
    private readonly daemon: DaemonSocket,
    local?: DaemonSocket,
  ) {
    this.local = local ?? daemon;
    this.sockets = this.local === daemon ? [daemon] : [daemon, this.local];
    this.cloud = new CloudHome(
      daemon,
      conversation,
      (summary) => {
        for (const listener of this.cloudListeners) listener(summary);
      },
      (participants) => {
        for (const listener of this.peopleListeners) listener(participants);
      },
    );
    this.people = new DaemonPeople(
      this.local,
      () => this.me,
      (capability) => this.capable(capability),
    );
  }

  /** People and Chiefs on the local owner (the sheets' directory, starts, invites, Chief records). */
  private readonly people: DaemonPeople;

  /** A local owner summary as the page's row, with my list state (kept when the summary has none). */
  private localRow(raw: Json): HomeConversation {
    const id = String(raw.id);
    let row: HomeConversation;
    if ("pinned" in raw || "marked_unread" in raw) {
      this.listState.set(id, { pinned: raw.pinned, pin_position: raw.pin_position, marked_unread: raw.marked_unread });
      row = conversation(raw, this.me);
    } else row = conversation({ ...raw, ...this.listState.get(id) }, this.me);
    const owned = this.homeRows.get(id);
    return owned ? withHomeRow(row, owned) : row;
  }

  private capable(capability: string, socket: DaemonSocket = this.local): Promise<boolean> {
    let list = this.capabilities.get(socket);
    if (!list) {
      list = socket
        .request<{ capabilities?: string[] }>("identify")
        .then((identity) => identity.capabilities ?? [])
        .catch(() => []);
      this.capabilities.set(socket, list);
    }
    return list.then((names) => names.includes(capability));
  }

  /** Whether this daemon serves the cloud owners to a page (an older one does not: local only). */
  private cloudReady(): Promise<boolean> {
    return this.capable(WS_CLOUD_CAPABILITY, this.daemon);
  }

  async call<R>(op: string, rawParams: unknown, options?: PageCallOptions): Promise<R> {
    const params = (rawParams ?? {}) as Json;
    try {
      return (await this.dispatch(op, params, options)) as R;
    } catch (error) {
      if (error instanceof Error && (error as DaemonError).code !== undefined && error.name === "DaemonError") {
        const code = (error as DaemonError).code;
        if (code === "conversation_rejected") throw pageError("cmux.page.invalid_params", error.message);
        if (code === "disconnected") throw pageError("cmux.page.unavailable", "the cmux instance is offline", true);
        // The app signed out (or switched accounts): the cloud inbox is listed again.
        if (code === "cloud_signed_out") this.cloud.reset();
        throw pageError(`cmux.home.${code}`, error.message);
      }
      throw error;
    }
  }

  private key(params: Json, options?: PageCallOptions): string {
    const key = (params.idempotencyKey as string | undefined) ?? options?.opid;
    return key ?? `page-${Date.now().toString(36)}-${this.nextKey++}`;
  }

  private async submit(conversationId: string, key: string, op: Json): Promise<Json> {
    if (this.cloud.owns(conversationId)) {
      const sent = await this.cloud.op(conversationId, key, op);
      return { rev: num(sent.rev), replayed: sent.replayed === true, conversation: conversationId };
    }
    const result = await this.local.request("conversation-op", {
      conversation: conversationId,
      idempotency_key: key,
      op,
    });
    return { rev: num(result.rev), replayed: result.replayed === true, conversation: conversationId };
  }

  /** A read of the conversation's owner: the local one, or a cloud owner through the daemon. */
  private read(cmd: string, id: string, params: Json): Promise<Json> {
    if (this.cloud.owns(id)) return this.cloud.read(`cloud-${cmd}`, params);
    return this.local.request(cmd, params);
  }

  private async dispatch(op: string, params: Json, options?: PageCallOptions): Promise<unknown> {
    switch (op) {
      case HomeOps.inbox: {
        const list = await this.local.request<{ conversations: Json[] }>("conversation-list");
        const summaries = list.conversations ?? [];
        const mine = summaries
          .flatMap((entry) => (entry.participants as Json[]) ?? [])
          .find((entry) => entry.id === LOCAL_USER);
        const me = mine ? participant(mine) : { id: LOCAL_USER, kind: "human" as const, name: "You", chief: false };
        this.me = me.id;
        // The owner's rows for the local conversations (an older daemon: the page projects them).
        this.homeRows.clear();
        if (await this.capable(HOME_INBOX_CAPABILITY)) {
          // A failed read leaves the page's own projection (never an empty list).
          const home = await this.local.request<{ me?: string; rows?: Json[] }>("home-inbox").catch(() => undefined);
          if (home && home.me === this.me) for (const row of home.rows ?? []) this.homeRows.set(String(row.id), row);
        }
        // The person's Cloud inbox through the same daemon; a Cloud failure never hides the local one.
        const cloud = await this.cloud.inbox(await this.cloudReady()).catch(() => []);
        return {
          me,
          conversations: [...summaries.map((entry) => this.localRow(entry)), ...cloud],
          rev: Math.max(0, ...summaries.map((entry) => num(entry.rev))),
          inboxState: await this.capable(INBOX_STATE_CAPABILITY),
        };
      }
      case HomeOps.page: {
        this.opened.add(str(params, "conversation"));
        const page = await this.read("conversation-snapshot", str(params, "conversation"), {
          conversation: str(params, "conversation"),
          tail: bounded(params.tail, 100),
        });
        const id = str(params, "conversation");
        return {
          conversation: this.cloud.summary(id) ?? this.localRow(page.conversation as Json),
          messages: ((page.messages as Json[]) ?? []).map(message),
          threads: threads(page.threads),
        };
      }
      case HomeOps.history: {
        const page = await this.read("conversation-history", str(params, "conversation"), {
          conversation: str(params, "conversation"),
          before_seq: num(params.beforeSeq),
          limit: bounded(params.limit, 100),
        });
        return { messages: ((page.messages as Json[]) ?? []).map(message), threads: threads(page.threads) };
      }
      case HomeOps.thread: {
        const page = await this.read("conversation-thread", str(params, "conversation"), {
          conversation: str(params, "conversation"),
          root: str(params, "root"),
          after_seq: Math.max(0, num(params.afterSeq)),
          limit: bounded(params.limit, 100),
        });
        return {
          root: message(page.root as Json),
          replies: ((page.replies as Json[]) ?? []).map(message),
          hasMore: page.has_more === true,
          thread: threads([page.thread])[0],
        };
      }
      case HomeOps.resolveLink: {
        // Local conversations only; a Cloud conversation link is a later read (DESIGN.md G4).
        const resolved = await this.local.request<Json>("conversation-link-resolve", {
          url: str(params, "url", 512),
        });
        const result: HomeResolvedLink = {
          conversation: String((resolved.conversation as Json).id),
          path: ((resolved.path as unknown[]) ?? []).map(String),
        };
        if (resolved.message) result.message = message(resolved.message as Json);
        if (typeof resolved.thread_root === "string") result.threadRoot = resolved.thread_root;
        return result;
      }
      case HomeOps.search: {
        const found = await this.local.request<{ hits: Json[] }>("conversation-search", {
          query: str(params, "query", 200),
          limit: Math.min(bounded(params.limit, 20), 50),
        });
        return {
          hits: (found.hits ?? []).map((hit) => ({
            conversation: String(hit.conversation),
            message: {
              id: String(hit.message_id),
              conversation: String(hit.conversation),
              seq: num(hit.seq),
              author: String(hit.author),
              createdAt: time(hit.created_at),
              retracted: false,
              parts: [{ type: "text", text: String(hit.snippet ?? ""), mentions: [] }],
              reactions: [],
            } satisfies HomeMessage,
          })),
        };
      }
      case HomeOps.view: {
        const id = str(params, "conversation");
        // Only the Cloud owner has viewing presence; an older daemon has no command for it.
        if (!this.cloud.owns(id) || !(await this.capable(CLOUD_PRESENCE_CAPABILITY, this.daemon)))
          return { sent: false };
        return { sent: await this.cloud.presence(id, params.viewing === true) };
      }
      case HomeOps.read:
        return this.submit(str(params, "conversation"), this.key(params, options), {
          kind: "read_cursor.set",
          seq: Math.max(0, num(params.seq)),
        });
      case HomeOps.send: {
        const text = String(params.text ?? "").trim();
        const files = Array.isArray(params.attachments) ? params.attachments.map(wireAttachment) : [];
        if (files.length > 10) throw pageError("cmux.page.invalid_params", "attachments");
        if ((!text && files.length === 0) || text.length > 40_000) throw pageError("cmux.page.invalid_params", "text");
        const key = this.key(params, options);
        const parts: Json[] = [...(text ? [{ type: "text", text }] : []), ...files];
        const send: Json = { kind: "message.send", client_msg_id: key, parts };
        if (typeof params.threadRoot === "string" && params.threadRoot) send.thread_root = params.threadRoot;
        // The reply's parent at any depth (conversation-tree-v1): the owner keeps the top root.
        if (typeof params.replyTo === "string" && params.replyTo)
          send.reply_to = { message_id: params.replyTo, part_index: 0 };
        return this.submit(str(params, "conversation"), key, send);
      }
      case HomeOps.react: {
        const value = str(params, "value", 32);
        const tapback = typeof params.tapback === "string" ? params.tapback : undefined;
        return this.submit(str(params, "conversation"), this.key(params, options), {
          kind: params.remove === true ? "reaction.remove" : "reaction.add",
          message_id: str(params, "message"),
          part_index: Math.max(0, num(params.partIndex)),
          reaction: tapback ? { tapback } : { emoji: value },
        });
      }
      case HomeOps.edit: {
        const text = String(params.text ?? "").trim();
        if (!text) throw pageError("cmux.page.invalid_params", "text");
        return this.submit(str(params, "conversation"), this.key(params, options), {
          kind: "message.edit",
          message_id: str(params, "message"),
          parts: [{ type: "text", text }],
        });
      }
      case HomeOps.retract:
        return this.submit(str(params, "conversation"), this.key(params, options), {
          kind: "message.retract",
          message_id: str(params, "message"),
        });
      case HomeOps.updateThread: {
        // conversation-thread-objects-v1: the same op on the local owner and, through the
        // daemon's proxy, a Cloud owner. Empty title or owner clears it.
        const update: Json = { kind: "thread.update", root: str(params, "root") };
        if (typeof params.title === "string") update.title = params.title;
        if (params.status === "open" || params.status === "resolved") update.status = params.status;
        if (typeof params.owner === "string") update.owner = params.owner;
        if (Object.keys(update).length === 2) throw pageError("cmux.page.invalid_params", "thread");
        // An older daemon has no thread objects: say so instead of a malformed-op error.
        const owner = this.cloud.owns(str(params, "conversation")) ? this.daemon : this.local;
        if (!(await this.capable(THREAD_OBJECTS_CAPABILITY, owner)))
          throw pageError("cmux.page.unavailable", "this cmux instance has no thread objects");
        return this.submit(str(params, "conversation"), this.key(params, options), update);
      }
      case HomeOps.pin: {
        const pinned = params.pinned === true;
        // The pin time orders my pins across both owners (one merged list).
        const op: Json = pinned ? { kind: "inbox.pin", pinned, position: Date.now() } : { kind: "inbox.pin", pinned };
        return this.inboxOp(str(params, "conversation"), this.key(params, options), op);
      }
      case HomeOps.markUnread:
        return this.inboxOp(str(params, "conversation"), this.key(params, options), {
          kind: "inbox.mark_unread",
          unread: params.unread === true,
        });
      case HomeOps.runs: {
        const id = str(params, "conversation");
        if (this.cloud.owns(id)) return this.cloudRuns(id, params);
        if (!(await this.capable(RUNS_CAPABILITY))) return { runs: [], hasMore: false };
        const turns = ((params.turns as unknown[] | undefined) ?? []).filter(
          (turn): turn is string => typeof turn === "string" && turn.length > 0 && turn.length <= 128,
        );
        const request: Json = { conversation: id };
        if (turns.length > 0) request.turns = turns.slice(0, 200);
        else request.limit = Math.min(bounded(params.limit, 50), 200);
        const found = await this.read("conversation-runs", id, request);
        return {
          runs: ((found.runs as Json[] | undefined) ?? []).map(run),
          hasMore: found.has_more === true,
        };
      }
      case HomeOps.live: {
        const id = str(params, "conversation");
        // A Cloud owner answers `run.live.get` on the conversation's socket: a live event.
        if (this.cloud.owns(id)) {
          if (await this.capable(CLOUD_LIVE_CAPABILITY, this.daemon))
            await this.daemon.request("cloud-conversation-live", { conversation: id });
          return null;
        }
        if (!(await this.capable(LIVE_CAPABILITY))) return null;
        return liveSnapshot(await this.read("conversation-live", id, { conversation: id })) ?? null;
      }
      case HomeOps.avatar: {
        const id = str(params, "participant", 80);
        // Cloud answers another participant's picture only with a conversation both are in.
        const via = this.cloud.conversationWith(id);
        const fromCloud = async () =>
          (await this.capable(AVATARS_CAPABILITY, this.daemon))
            ? await this.cloud.read<Json>(
                "cloud-participant-avatar-get",
                via ? { participant_id: id, conversation: via } : { participant_id: id },
              )
            : null;
        // A Cloud person or Chief is known here only once a Cloud conversation naming them was read
        // (the list renders first), so a picture the local owner does not have is asked of Cloud too.
        const known = via !== undefined;
        // A refused Cloud read (not shared, not found) is no picture, kept like one.
        let found: Json | null = known
          ? await fromCloud().catch(() => null)
          : (await this.capable(AVATARS_CAPABILITY, this.local))
            ? await this.local.operation<Json>("participant.avatar.get", {
                machine: "current",
                session: "current",
                participant_id: id,
              })
            : null;
        if (!found?.avatar && id !== LOCAL_USER && !known) {
          found = (await fromCloud().catch(() => null)) ?? found;
        }
        const avatar = (found?.avatar ?? null) as Json | null;
        return {
          avatar: avatar
            ? { sha256: String(avatar.sha256), mediaType: String(avatar.media_type), data: String(avatar.data) }
            : null,
        };
      }
      case HomeOps.run: {
        const id = str(params, "conversation");
        // A Cloud Chief's run is read from its brain by agent, steps after a seq (no revisions).
        const page = this.cloud.owns(id)
          ? await this.cloud.read("cloud-conversation-run", {
              conversation: id,
              agent: str(params, "agent", 128),
              run: str(params, "run", 128),
              after_seq: Math.max(0, num(params.afterSeq)),
            })
          : await this.read("conversation-run", id, {
              conversation: id,
              run: str(params, "run", 128),
              after_rev: Math.max(0, num(params.afterRev)),
            });
        return {
          run: run(page.run as Json),
          steps: ((page.steps as Json[] | undefined) ?? []).map(runStep),
          hasMore: page.has_more === true,
        };
      }
      case HomeOps.createGroup:
        return this.createGroup(params, options);
      case HomeOps.capabilities:
        // New messages and invites are the local owner's (`conversation-create`, `participants.add`).
        return { start: true, invite: true, chiefs: await this.people.managesChiefs() };
      case HomeOps.directory:
        return { people: await this.people.directory(participant) };
      case HomeOps.startConversation: {
        const ids = Array.isArray(params.participants)
          ? params.participants.filter((id) => typeof id === "string")
          : [];
        const title = typeof params.title === "string" ? params.title.slice(0, 200) : "";
        return { conversation: await this.people.start(ids as string[], title, this.key(params, options)) };
      }
      case HomeOps.invite: {
        const id = str(params, "conversation");
        if (this.cloud.owns(id))
          throw pageError("cmux.page.unavailable", "invites to cloud conversations are not here yet");
        const ids = Array.isArray(params.participants) ? params.participants.filter((p) => typeof p === "string") : [];
        await this.people.invite(id, ids as string[], this.key(params, options));
        return { conversation: id };
      }
      case HomeOps.chiefs:
        return { chiefs: await this.people.chiefs() };
      case HomeOps.chiefUpdate:
        return {
          chief: await this.people.renameChief(str(params, "chief", 64), chiefNames(params), this.key(params, options)),
        };
      case HomeOps.chiefAvatarSet:
        return {
          chief: await this.people.setChiefAvatar(
            str(params, "chief", 64),
            params.clear === true
              ? null
              : { mediaType: str(params, "mediaType", 32), data: str(params, "data", 1_500_000) },
            this.key(params, options),
          ),
        };
      case HomeOps.chiefAvatar:
        return { avatar: await this.people.chiefAvatar(str(params, "chief", 64)) };
      case HomeOps.attachmentSupport:
        return {
          local: await this.capable(WS_ATTACHMENTS_CAPABILITY),
          cloud: (await this.cloudReady()) && (await this.capable(CLOUD_ATTACHMENTS_CAPABILITY, this.daemon)),
        };
      case HomeOps.attachmentUpload:
        return this.attachmentUpload(params);
      case HomeOps.attachmentRead: {
        const id = str(params, "conversation");
        const read: Json = { conversation: id, hash: str(params, "hash", 64) };
        if (typeof params.variant === "string") read.variant = params.variant;
        if (typeof params.offset === "number") read.offset = params.offset;
        if (typeof params.length === "number") read.length = params.length;
        const bytes = await this.attachmentSocket(id).request<Json>(this.attachmentCommand(id, "read"), read);
        return {
          mimeType: String(bytes.mime_type ?? ""),
          byteCount: num(bytes.byte_count),
          offset: num(bytes.offset),
          data: String(bytes.data ?? ""),
          eof: bytes.eof === true,
        };
      }
      case HomeOps.attachmentUrl: {
        const id = str(params, "conversation");
        const request: Json = { conversation: id, hash: str(params, "hash", 64) };
        if (typeof params.variant === "string") request.variant = params.variant;
        if (typeof params.name === "string" && params.name) request.name = params.name;
        const socket = this.attachmentSocket(id);
        const link = await socket.request<Json>(this.attachmentCommand(id, "link"), request);
        // The link is a path on that owner connection's own listener: its origin.
        const base = socket.url.replace(/^ws/, "http");
        return { url: new URL(String(link.path), base).toString(), expiresInMs: num(link.expires_in_ms) };
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  /** My own list state of one conversation, on its owner: the local owner keeps it beside the
   * conversation, a Cloud owner in my UserDO inbox (through the daemon). */
  private async inboxOp(conversationId: string, key: string, op: Json): Promise<unknown> {
    const owner = this.cloud.owns(conversationId) ? this.daemon : this.local;
    if (!(await this.capable(INBOX_STATE_CAPABILITY, owner)))
      throw pageError("cmux.page.unavailable", "this cmux instance keeps no pins");
    if (this.cloud.owns(conversationId)) {
      await this.daemon.request("cloud-inbox-op", { conversation: conversationId, idempotency_key: key, op });
      return { conversation: conversationId };
    }
    // What the list state will be, at once: a conversation change that lands before the owner's
    // answer keeps it (the page shows it already); a refusal puts the old state back.
    const before = this.listState.get(conversationId);
    const next: Json = { ...before };
    if (op.kind === "inbox.pin") {
      next.pinned = op.pinned === true;
      next.pin_position = op.pinned === true ? (op.position ?? before?.pin_position) : undefined;
    } else next.marked_unread = op.unread === true;
    this.listState.set(conversationId, next);
    try {
      const state = await this.local.request<Json>("conversation-inbox-op", { conversation: conversationId, op });
      this.listState.set(conversationId, {
        pinned: state.pinned,
        pin_position: state.pin_position,
        marked_unread: state.marked_unread,
      });
    } catch (error) {
      if (this.listState.get(conversationId) === next) {
        if (before) this.listState.set(conversationId, before);
        else this.listState.delete(conversationId);
      }
      throw error;
    }
    return { conversation: conversationId };
  }

  /** The command of one attachment step for the conversation's owner: the local owner's, or the
   * same command through the daemon's cloud lease (`cloud-attachments-v1`). */
  private attachmentCommand(conversationId: string, step: "upload" | "read" | "link"): string {
    return `${this.cloud.owns(conversationId) ? "cloud" : "conversation"}-attachment-${step}`;
  }

  /** The connection that serves a conversation's attachments: the local owner, or the daemon with
   * the cloud lease. */
  private attachmentSocket(conversationId: string): DaemonSocket {
    return this.cloud.owns(conversationId) ? this.daemon : this.local;
  }

  /** One upload step (`*-attachment-upload`), fields as the owner names them. A step after `begin`
   * names only its upload, which keeps the owner its `begin` chose. */
  private async attachmentUpload(params: Json): Promise<unknown> {
    const op = str(params, "op", 16);
    if (!UPLOAD_STEPS.has(op)) throw pageError("cmux.page.invalid_params", "op");
    const upload = typeof params.upload === "string" ? params.upload : "";
    const cloud = op === "begin" ? this.cloud.owns(str(params, "conversation")) : this.cloudUploads.has(upload);
    const request: Json = { op };
    for (const field of [
      "conversation",
      "sha256",
      "byte_count",
      "mime_type",
      "name",
      "width",
      "height",
      "duration_ms",
      "poster",
      "preview",
      "upload",
      "piece",
      "offset",
      "data",
    ])
      if (params[field] !== undefined) request[field] = params[field];
    const reply = cloud
      ? await this.daemon.request<Json>("cloud-attachment-upload", request)
      : await this.local.request<Json>("conversation-attachment-upload", request);
    if (op === "begin" && cloud && typeof reply.upload === "string") this.cloudUploads.add(reply.upload);
    if (op === "commit" || op === "cancel") this.cloudUploads.delete(upload);
    return reply;
  }

  /** A Cloud conversation's runs: each Chief of it keeps its own (the Cloud brain's reads, by
   * agent), merged newest first. A daemon without the proxy answers nothing. */
  private async cloudRuns(id: string, params: Json): Promise<{ runs: HomeRun[]; hasMore: boolean }> {
    // The brain lists newest first only: a read by reply keys has nothing more to find.
    if (!(await this.capable(CLOUD_RUNS_CAPABILITY, this.daemon)) || Array.isArray(params.turns))
      return { runs: [], hasMore: false };
    const agents = (this.cloud.summary(id)?.participants ?? [])
      .filter((participant) => participant.kind === "agent")
      .map((participant) => participant.id)
      .slice(0, 8);
    const limit = Math.min(bounded(params.limit, 20), 100);
    const lists = await Promise.all(
      agents.map((agent) =>
        this.cloud
          .read("cloud-conversation-runs", { conversation: id, agent, limit })
          .then((found) => ((found.runs as Json[] | undefined) ?? []).map(run))
          .catch(() => [] as HomeRun[]),
      ),
    );
    const runs = lists.flat().sort((a, b) => b.startedAt - a.startedAt);
    return { runs, hasMore: false };
  }

  /** A channel of the local user and known local participants (the Chief when none is named);
   * the same rule as the app's local owner (DaemonHomeSource+Create). */
  private async createGroup(params: Json, options?: PageCallOptions): Promise<unknown> {
    const title = str(params, "title", 80).trim();
    if (!title) throw pageError("cmux.page.invalid_params", "title");
    const ids = ((params.participants as unknown[]) ?? []).filter((id): id is string => typeof id === "string" && !!id);
    const list = await this.local.request<{ conversations: Json[] }>("conversation-list");
    const known = new Map<string, Json>([[CHIEF.id, CHIEF]]);
    for (const summary of list.conversations ?? [])
      for (const entry of (summary.participants as Json[]) ?? [])
        if (!known.has(String(entry.id))) known.set(String(entry.id), entry);
    const members: Json[] = [known.get(this.me) ?? { id: this.me, kind: "human", display_name: "You" }];
    for (const id of ids.length ? ids : [CHIEF.id]) {
      if (id === this.me || members.some((entry) => entry.id === id)) continue;
      const entry = known.get(id);
      if (!entry) throw pageError("cmux.page.invalid_params", "unknown_participant");
      members.push(entry);
    }
    const created = await this.local.request("conversation-create", {
      idempotency_key: this.key(params, options),
      title,
      participants: members,
    });
    return { rev: 0, replayed: created.replayed === true, conversation: String((created.conversation as Json).id) };
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === PAGE_CONNECTION) {
      // The page's own link to its owners: these daemon connections (either one lost is offline).
      queueMicrotask(() => onEvent({ connected: true } as E, 1));
      const offs = this.sockets.map((socket) => socket.onClose(() => onEvent({ connected: false } as E, 2)));
      return () => offs.forEach((off) => off());
    }
    if (stream !== HomeOps.events) throw pageError("cmux.protocol.unknown_op", stream);
    let seq = 0;
    let pending: HomeEventBatch | null = null;
    // One batch per microtask turn: a burst of daemon events costs one page update.
    const deliver = (patch: (batch: HomeEventBatch) => void) => {
      const first = pending === null;
      pending ??= {};
      patch(pending);
      if (first)
        queueMicrotask(() => {
          const batch = pending;
          pending = null;
          if (batch) onEvent(batch as E, ++seq);
        });
    };
    const offCloud = (() => {
      const listener = (summary: HomeConversation) => deliver((batch) => (batch.conversations ??= []).push(summary));
      const people = (participants: string[]) => deliver((batch) => (batch.avatars ??= []).push(...participants));
      this.cloudListeners.add(listener);
      this.peopleListeners.add(people);
      return () => {
        this.cloudListeners.delete(listener);
        this.peopleListeners.delete(people);
      };
    })();
    // Cloud events come from the build daemon, local conversation events from the local owner
    // (the same socket unless the Chief home's owner serves the local conversations).
    const onSocketEvent = (socket: DaemonSocket) => (event: Json) => {
      const fromCloud = socket === this.daemon;
      const fromLocal = socket === this.local;
      const cloud =
        fromCloud && typeof event.event === "string" && event.event.startsWith("cloud-")
          ? this.cloud.event(event)
          : null;
      if (cloud) {
        deliver((batch) => {
          if (cloud.message) (batch.messages ??= []).push(message(cloud.message));
          if (cloud.conversation) (batch.conversations ??= []).push(cloud.conversation);
          if (cloud.conversations?.length) (batch.conversations ??= []).push(...cloud.conversations);
          if (cloud.removed?.length) (batch.removed ??= []).push(...cloud.removed);
          if (cloud.stale) (batch.stale ??= []).push(cloud.stale);
          if (cloud.inboxStale) batch.inboxStale = true;
          if (cloud.typing) (batch.typing ??= []).push(cloud.typing);
          if (cloud.presence) (batch.presence ??= []).push(cloud.presence);
          if (cloud.live) {
            const frame = liveFrame(cloud.live);
            if (frame) (batch.live ??= []).push(frame);
          }
          if (cloud.run) {
            const changed = run(cloud.run.run);
            // A Cloud brain's run carries no update time: this event is its newest change.
            if (!changed.updatedAt) changed.updatedAt = Date.now();
            (batch.runs ??= []).push({ run: changed, steps: cloud.run.steps.map(runStep) });
          }
        });
      } else if (!fromLocal && event.event !== "overflow") {
        // The build daemon's own local conversations are not shown while another owner serves them.
      } else if (event.event === "conversation-changed") {
        const change = (event.change ?? {}) as Json;
        if ((change.kind === "message" || change.kind === "message-updated") && change.message) {
          deliver((batch) => {
            (batch.messages ??= []).push(message(change.message as Json));
            // The summary (last seq, unread, preview) changed too: the page rereads the inbox.
            batch.inboxStale = true;
          });
        } else if (change.kind === "conversation" && change.conversation) {
          deliver((batch) => {
            (batch.conversations ??= []).push(this.localRow(change.conversation as Json));
            // Its row (kind, name) is the owner's: read the rows again.
            if (this.homeRows.size > 0) batch.inboxStale = true;
          });
        } else {
          deliver((batch) => (batch.inboxStale = true));
        }
      } else if (event.event === "conversation-inbox-changed") {
        // My own pin or mark (the daemon sends only mine).
        deliver((batch) => {
          const change: HomeInboxChange = {
            conversation: String(event.conversation),
            pinned: event.pinned === true,
            markedUnread: event.marked_unread === true,
          };
          if (change.pinned && typeof event.pin_position === "number") change.pinPosition = event.pin_position;
          this.listState.set(change.conversation, {
            pinned: change.pinned,
            pin_position: change.pinPosition,
            marked_unread: change.markedUnread,
          });
          (batch.inbox ??= []).push(change);
        });
      } else if (event.event === "conversation-presence") {
        deliver((batch) =>
          (batch.presence ??= []).push({
            conversation: String(event.conversation),
            participants: Array.isArray(event.participants)
              ? (event.participants as Json[])
                  .filter((p) => p && typeof p.participant === "string")
                  .map((p) => ({ participant: String(p.participant), viewing: p.viewing === true }))
              : [],
          }),
        );
      } else if (event.event === "conversation-typing") {
        deliver((batch) => {
          (batch.typing ??= []).push({
            conversation: String(event.conversation),
            participant: String(event.participant),
            on: event.on === true,
          });
          // The Chief stopped typing: its "working" on the owner's row may end.
          const owned = this.homeRows.get(String(event.conversation));
          if (event.on !== true && owned?.chief === event.participant && owned?.chief_state === "working")
            batch.inboxStale = true;
        });
      } else if (event.event === "conversation-draft") {
        const item = (event.item ?? {}) as Json;
        deliver((batch) =>
          (batch.drafts ??= []).push({
            conversation: String(event.conversation),
            participant: String(event.participant),
            turn: String(item.turn ?? ""),
            segment: num(item.segment),
            seq: num(item.seq),
            talk: item.kind !== "thought",
            text: String(item.text ?? ""),
            fresh: item.fresh === true,
            done: item.done === true,
          }),
        );
      } else if (event.event === "participant-avatar-changed" && typeof event.participant === "string") {
        const participant = event.participant;
        deliver((batch) => (batch.avatars ??= []).push(participant));
      } else if (event.event === "conversation-run-changed" && event.run) {
        deliver((batch) => {
          (batch.runs ??= []).push({
            run: run(event.run as Json),
            steps: ((event.steps as Json[] | undefined) ?? []).map(runStep),
          });
          // A run that ended may end its Chief's "working" on the owner's row (a run that starts
          // shows at once: the page's own runs make the Chief active).
          if (this.homeRows.size > 0 && (event.run as Json).status !== "running") batch.inboxStale = true;
        });
      } else if (event.event === "conversation-live" && event.frame && typeof event.frame === "object") {
        const frame = liveFrame(event.frame as Json);
        if (frame) deliver((batch) => (batch.live ??= []).push(frame));
      } else if (event.event === "overflow") {
        // The daemon ended the stream ("resubscribe to continue"): start it again, and refetch
        // what the lost events changed (the inbox and every open window).
        this.streamStarted.delete(socket);
        // Lost cloud events too: the cloud inbox is listed again with the inbox.
        if (fromCloud) this.cloud.reset();
        void this.startSocketStream(socket).catch(() => deliver((batch) => (batch.connection = "offline")));
        deliver((batch) => {
          batch.inboxStale = true;
          batch.stale = [...this.opened];
          batch.presenceLost = true;
        });
      }
    };
    const offEvents = this.sockets.map((socket) => socket.onEvent(onSocketEvent(socket)));
    const offEvent = () => offEvents.forEach((off) => off());
    const offCloses = this.sockets.map((socket) =>
      socket.onClose(() => deliver((batch) => (batch.connection = "offline"))),
    );
    const offClose = () => offCloses.forEach((off) => off());
    try {
      await this.startStream();
    } catch (error) {
      offEvent();
      offClose();
      offCloud();
      throw error;
    }
    deliver((batch) => {
      batch.connection = "online";
      batch.inboxStale = true;
    });
    return () => {
      offEvent();
      offClose();
      offCloud();
    };
  }

  handle(_op: string, _handler: PageHandler): () => void {
    // The daemon calls no page op.
    return () => {};
  }
}
