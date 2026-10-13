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
  type HomeConversation,
  type HomeEventBatch,
  type HomeMessage,
  type HomeParticipant,
  type HomePart,
  type HomeReaction,
  type HomeThreadStats,
} from "./types";

type Json = Record<string, unknown>;

const LOCAL_USER = "user_local";
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
    name: chief ? "Chief" : String(raw.display_name ?? raw.id),
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
      return {
        type: "attachment",
        name: String(raw.name ?? ""),
        mimeType: String(raw.mime_type ?? ""),
        byteCount: num(raw.byte_count),
        hash: String(raw.hash ?? ""),
      };
    case "link_preview":
      return { type: "other", text: String(raw.url ?? "") };
    default:
      return { type: "other", text: String(raw.type ?? "") };
  }
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
  if (replyTo) result.replyTo = { message: replyTo.message_id, partIndex: replyTo.part_index };
  // A message from before threads marked its thread as a reply to the root (HomeCoreMapping).
  const root = (raw.thread_root as string | undefined) ?? replyTo?.message_id;
  if (root) result.threadRoot = root;
  return result;
}

function plain(raw: Json | undefined): string | undefined {
  if (!raw || raw.retracted_at) return undefined;
  return ((raw.parts as Json[] | undefined) ?? [])
    .map((item) => (item.type === "text" ? String(item.text ?? "") : ""))
    .join(" ")
    .slice(0, 200);
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
  /** The cloud owners through this daemon; `cloudCapable` once `identify` names the capability. */
  private readonly cloud: CloudHome;
  private cloudCapable: Promise<boolean> | null = null;
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

  /** Whether this daemon serves the cloud owners to a page (an older one does not: local only). */
  private cloudReady(): Promise<boolean> {
    this.cloudCapable ??= this.daemon
      .request<{ capabilities?: string[] }>("identify")
      .then((identity) => identity.capabilities?.includes(WS_CLOUD_CAPABILITY) === true)
      .catch(() => false);
    return this.cloudCapable;
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
        if (!text || text.length > 40_000) throw pageError("cmux.page.invalid_params", "text");
        const key = this.key(params, options);
        const send: Json = { kind: "message.send", client_msg_id: key, parts: [{ type: "text", text }] };
        if (typeof params.threadRoot === "string" && params.threadRoot) send.thread_root = params.threadRoot;
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
      case HomeOps.createGroup:
        return this.createGroup(params, options);
      default:
        throw pageError("cmux.protocol.unknown_op", op);
    }
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
      const cloud = typeof event.event === "string" && event.event.startsWith("cloud-") ? this.cloud.event(event) : null;
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
