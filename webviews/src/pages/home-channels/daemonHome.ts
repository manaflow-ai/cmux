// The `cmux.home.*` page namespace served straight from the cmux instance's daemon over its
// WebSocket (ws-conversations-v1): the local conversation owner's raw `conversation-*` commands and
// `subscribe` events, projected into the page's shapes (types.ts). The same rules the app's Home
// applies (CmuxHomeCore `ConversationSummary.kind` and `unreadCount`, HomeCoreMapping): no Swift in
// the data path, so the page runs the same in a plain browser, the app's web view, Chromium and
// GPUI. Cloud conversations come through the same daemon (cloudHome.ts, ws-cloud-conversations-v1)
// and merge into the one inbox. Slice 3 moves this projection into the daemon as `home.*` operations.
import { pageError, type PageClient, type PageCallOptions, type PageHandler } from "../shared/pageClient";
import { PAGE_CONNECTION } from "../shared/pageStreams";
import type { DaemonError, DaemonSocket } from "../shared/daemonSocket";
import { CloudHome, WS_CLOUD_CAPABILITY } from "./cloudHome";
import {
  HomeOps,
  type HomeAttachment,
  type HomeConversation,
  type HomeDerivedImage,
  type HomeEventBatch,
  type HomeMessage,
  type HomeParticipant,
  type HomePart,
  type HomeReaction,
  type HomeResolvedLink,
  type HomeThreadObject,
  type HomeThreadStats,
} from "./types";

type Json = Record<string, unknown>;

const LOCAL_USER = "user_local";
/** `thread.update`, `Message.thread` and the thread object fields of the stats. */
const THREAD_OBJECTS_CAPABILITY = "conversation-thread-objects-v1";
/** Attachment uploads, reads and download links on this WebSocket (local conversations). */
const WS_ATTACHMENTS_CAPABILITY = "ws-attachments-v1";
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
    pinned: false,
  };
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

function str(params: Json, field: string, max = 256): string {
  const value = params[field];
  if (typeof value !== "string" || !value || value.length > max) throw pageError("cmux.page.invalid_params", field);
  return value;
}

/** Serves the page namespace from the daemon; one instance per page. */
export class DaemonHomeClient implements PageClient {
  private me = LOCAL_USER;
  private nextKey = 1;
  /** The one daemon `subscribe` stream of this connection; page subscriptions share it. */
  private streamStarted: Promise<void> | null = null;
  /** Conversations whose page the page read (refetched after a lost event). */
  private readonly opened = new Set<string>();
  /** The cloud owners through this daemon (when `identify` names the capability). */
  private readonly cloud: CloudHome;
  /** The daemon's `identify` capabilities, read once. */
  private capabilities: Promise<string[]> | null = null;
  /** Cloud summaries the hydration read after the inbox answered (sent on the events stream). */
  private readonly cloudListeners = new Set<(conversation: HomeConversation) => void>();

  /** Starts the daemon stream once per connection (a page resubscribe adds a listener only). */
  private startStream(): Promise<void> {
    this.streamStarted ??= (async () => {
      await this.daemon.request("set-client-info", {
        name: "cmux page: home-channels",
        capabilities: ["conversation-draft-events-v1"],
      });
      await this.daemon.request("subscribe");
    })().catch((error) => {
      this.streamStarted = null;
      throw error;
    });
    return this.streamStarted;
  }

  constructor(private readonly daemon: DaemonSocket) {
    this.cloud = new CloudHome(daemon, conversation, (summary) => {
      for (const listener of this.cloudListeners) listener(summary);
    });
  }

  private capable(capability: string): Promise<boolean> {
    this.capabilities ??= this.daemon
      .request<{ capabilities?: string[] }>("identify")
      .then((identity) => identity.capabilities ?? [])
      .catch(() => []);
    return this.capabilities.then((list) => list.includes(capability));
  }

  /** Whether this daemon serves the cloud owners to a page (an older one does not: local only). */
  private cloudReady(): Promise<boolean> {
    return this.capable(WS_CLOUD_CAPABILITY);
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
    const result = await this.daemon.request("conversation-op", {
      conversation: conversationId,
      idempotency_key: key,
      op,
    });
    return { rev: num(result.rev), replayed: result.replayed === true, conversation: conversationId };
  }

  /** A read of the conversation's owner: the local one, or a cloud owner through the daemon. */
  private read(cmd: string, id: string, params: Json): Promise<Json> {
    if (this.cloud.owns(id)) return this.cloud.read(`cloud-${cmd}`, params);
    return this.daemon.request(cmd, params);
  }

  private async dispatch(op: string, params: Json, options?: PageCallOptions): Promise<unknown> {
    switch (op) {
      case HomeOps.inbox: {
        const list = await this.daemon.request<{ conversations: Json[] }>("conversation-list");
        const summaries = list.conversations ?? [];
        const mine = summaries
          .flatMap((entry) => (entry.participants as Json[]) ?? [])
          .find((entry) => entry.id === LOCAL_USER);
        const me = mine ? participant(mine) : { id: LOCAL_USER, kind: "human" as const, name: "You", chief: false };
        this.me = me.id;
        // The person's Cloud inbox through the same daemon; a Cloud failure never hides the local one.
        const cloud = await this.cloud.inbox(await this.cloudReady()).catch(() => []);
        return {
          me,
          conversations: [...summaries.map((entry) => conversation(entry, this.me)), ...cloud],
          rev: Math.max(0, ...summaries.map((entry) => num(entry.rev))),
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
          conversation: this.cloud.summary(id) ?? conversation(page.conversation as Json, this.me),
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
        const resolved = await this.daemon.request<Json>("conversation-link-resolve", {
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
        const found = await this.daemon.request<{ hits: Json[] }>("conversation-search", {
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
        if (!(await this.capable(THREAD_OBJECTS_CAPABILITY)))
          throw pageError("cmux.page.unavailable", "this cmux instance has no thread objects");
        return this.submit(str(params, "conversation"), this.key(params, options), update);
      }
      case HomeOps.createGroup:
        return this.createGroup(params, options);
      case HomeOps.attachmentSupport:
        // Cloud conversations take attachments once the daemon proxies the cloud upload.
        return { local: await this.capable(WS_ATTACHMENTS_CAPABILITY), cloud: false };
      case HomeOps.attachmentUpload:
        return this.attachmentUpload(params);
      case HomeOps.attachmentRead: {
        const id = str(params, "conversation");
        this.localAttachments(id);
        const read: Json = { conversation: id, hash: str(params, "hash", 64) };
        if (typeof params.variant === "string") read.variant = params.variant;
        if (typeof params.offset === "number") read.offset = params.offset;
        if (typeof params.length === "number") read.length = params.length;
        const bytes = await this.daemon.request<Json>("conversation-attachment-read", read);
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
        this.localAttachments(id);
        const request: Json = { conversation: id, hash: str(params, "hash", 64) };
        if (typeof params.variant === "string") request.variant = params.variant;
        if (typeof params.name === "string" && params.name) request.name = params.name;
        const link = await this.daemon.request<Json>("conversation-attachment-link", request);
        // The link is a path on the daemon's own listener: this connection's origin.
        const base = this.daemon.url.replace(/^ws/, "http");
        return { url: new URL(String(link.path), base).toString(), expiresInMs: num(link.expires_in_ms) };
      }
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
  }

  /** Attachments of a Cloud conversation need the daemon's cloud upload (not yet): say so. */
  private localAttachments(conversationId: string): void {
    if (this.cloud.owns(conversationId))
      throw pageError("cmux.page.unavailable", "attachments of cloud conversations are not available here yet");
  }

  /** One upload step for the local owner (`conversation-attachment-upload`), fields as the owner names them. */
  private async attachmentUpload(params: Json): Promise<unknown> {
    const op = str(params, "op", 16);
    if (!UPLOAD_STEPS.has(op)) throw pageError("cmux.page.invalid_params", "op");
    if (op === "begin") this.localAttachments(str(params, "conversation"));
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
    return this.daemon.request("conversation-attachment-upload", request);
  }

  /** A channel of the local user and known local participants (the Chief when none is named);
   * the same rule as the app's local owner (DaemonHomeSource+Create). */
  private async createGroup(params: Json, options?: PageCallOptions): Promise<unknown> {
    const title = str(params, "title", 80).trim();
    if (!title) throw pageError("cmux.page.invalid_params", "title");
    const ids = ((params.participants as unknown[]) ?? []).filter((id): id is string => typeof id === "string" && !!id);
    const list = await this.daemon.request<{ conversations: Json[] }>("conversation-list");
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
    const created = await this.daemon.request("conversation-create", {
      idempotency_key: this.key(params, options),
      title,
      participants: members,
    });
    return { rev: 0, replayed: created.replayed === true, conversation: String((created.conversation as Json).id) };
  }

  async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void): Promise<() => void> {
    if (stream === PAGE_CONNECTION) {
      // The page's own link to its owner: this daemon connection.
      queueMicrotask(() => onEvent({ connected: true } as E, 1));
      return this.daemon.onClose(() => onEvent({ connected: false } as E, 2));
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
      this.cloudListeners.add(listener);
      return () => this.cloudListeners.delete(listener);
    })();
    const offEvent = this.daemon.onEvent((event) => {
      const cloud =
        typeof event.event === "string" && event.event.startsWith("cloud-") ? this.cloud.event(event) : null;
      if (cloud) {
        deliver((batch) => {
          if (cloud.message) (batch.messages ??= []).push(message(cloud.message));
          if (cloud.conversation) (batch.conversations ??= []).push(cloud.conversation);
          if (cloud.conversations?.length) (batch.conversations ??= []).push(...cloud.conversations);
          if (cloud.removed?.length) (batch.removed ??= []).push(...cloud.removed);
          if (cloud.stale) (batch.stale ??= []).push(cloud.stale);
          if (cloud.inboxStale) batch.inboxStale = true;
        });
      } else if (event.event === "conversation-changed") {
        const change = (event.change ?? {}) as Json;
        if ((change.kind === "message" || change.kind === "message-updated") && change.message) {
          deliver((batch) => {
            (batch.messages ??= []).push(message(change.message as Json));
            // The summary (last seq, unread, preview) changed too: the page rereads the inbox.
            batch.inboxStale = true;
          });
        } else if (change.kind === "conversation" && change.conversation) {
          deliver((batch) => (batch.conversations ??= []).push(conversation(change.conversation as Json, this.me)));
        } else {
          deliver((batch) => (batch.inboxStale = true));
        }
      } else if (event.event === "conversation-typing") {
        deliver((batch) =>
          (batch.typing ??= []).push({
            conversation: String(event.conversation),
            participant: String(event.participant),
            on: event.on === true,
          }),
        );
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
      } else if (event.event === "overflow") {
        // The daemon ended the stream ("resubscribe to continue"): start it again, and refetch
        // what the lost events changed (the inbox and every open window).
        this.streamStarted = null;
        // Lost cloud events too: the cloud inbox is listed again with the inbox.
        this.cloud.reset();
        void this.startStream().catch(() => deliver((batch) => (batch.connection = "offline")));
        deliver((batch) => {
          batch.inboxStale = true;
          batch.stale = [...this.opened];
        });
      }
    });
    const offClose = this.daemon.onClose(() => deliver((batch) => (batch.connection = "offline")));
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
