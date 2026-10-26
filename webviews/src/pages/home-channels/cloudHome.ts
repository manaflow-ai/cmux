// The person's Cloud conversations in the Channels page, through this instance's daemon
// (`ws-cloud-conversations-v1`): the daemon keeps the Cloud session the app leased and proxies the
// cloud owners (`cloud-inbox-list`, `cloud-conversation-*`, the `cloud-*` events). The page never
// sees a Cloud credential. The person's Cloud participant id (`cloud-session-status`
// `participant`) is shown as the page's own `me` (`user_local`), the same rule as the app's
// CloudIdentity, so local and cloud conversations share one `me`. Slice 3 moves this merge into the
// daemon as `home.*` operations (hq ARCHITECTURE.md section 14).
import type { DaemonSocket } from "../shared/daemonSocket";
import type { HomeConversation, HomeParticipant } from "./types";

type Json = Record<string, unknown>;

export const WS_CLOUD_CAPABILITY = "ws-cloud-conversations-v1";
const LOCAL_USER = "user_local";
/** Snapshot reads that name an inbox entry's people run at most this many at once. */
const HYDRATION_WIDTH = 4;
/** The daemon keeps one upstream socket per subscribed conversation and shares its bound with
 * the app; the page keeps its own share small (the least recent ends). */
const MAX_SUBSCRIPTIONS = 16;
/** The cloud owner's snapshot `tail` bound (cmux-tui-cloud-conversations MAX_TAIL). */
const MAX_TAIL = 50;

const num = (value: unknown): number => (typeof value === "number" ? value : 0);
const time = (value: unknown): number => (typeof value === "string" ? Date.parse(value) || 0 : 0);

/** One page connection's view of the Cloud owners. */
export class CloudHome {
  /** The person's Cloud participant id, while the daemon holds the app's lease. */
  private participant: string | null = null;
  /** The inbox entries as the owner listed or pushed them, by conversation. */
  private entries = new Map<string, Json>();
  /** The newest head read per conversation (participants, cursors, last message). */
  private readonly heads = new Map<string, Json>();
  private listed = false;
  /** The one inbox list in flight (concurrent page reloads share it). */
  private listing: Promise<void> | null = null;
  /** Bumped by `reset`: a list that a reset overtook does not count as listed. */
  private epoch = 0;
  /** Every cloud id this connection saw: routing survives a relist (`owns`). */
  private readonly known = new Set<string>();
  private readonly hydrating = new Set<string>();
  private readonly hydrationQueue: string[] = [];
  private hydrationWorkers = 0;
  private readonly subscribed: string[] = [];

  constructor(
    private readonly daemon: DaemonSocket,
    /** daemonHome's projection of an owner head (the same rules for local and cloud). */
    private readonly project: (raw: Json, me: string) => HomeConversation,
    /** Pushes a changed cloud summary to the page (the events stream). */
    private readonly changed: (conversation: HomeConversation) => void,
    /** Participants a head names for the first time: their Cloud picture can be read now (with
     *  that conversation), so the page asks again instead of keeping an earlier refusal. */
    private readonly peopleSeen: (participants: string[]) => void = () => {},
  ) {}

  /** Participants some head named (the pictures asked again once, `peopleSeen`). */
  private readonly seen = new Set<string>();

  private keepHead(id: string, head: Json): void {
    this.heads.set(id, head);
    const people = Array.isArray(head.participants) ? (head.participants as Json[]) : [];
    // A member who left is not marked: a later head where they are present re-asks them.
    const fresh = people
      .filter((person) => (person as Json | null)?.left_at === undefined)
      .map((person) => (person as Json | null)?.id)
      .filter((pid): pid is string => typeof pid === "string" && pid !== LOCAL_USER && !this.seen.has(pid));
    for (const pid of fresh) this.seen.add(pid);
    if (fresh.length) this.peopleSeen(fresh);
  }

  /** Whether `id` is a cloud conversation this page knows. */
  owns(id: string): boolean {
    return this.known.has(id);
  }

  /** Whether participant `id` (not the person) is in a cloud conversation this page read: its
   *  picture is the Cloud owner's. */
  hasParticipant(id: string): boolean {
    return this.conversationWith(id) !== undefined;
  }

  /** A cloud conversation this page knows that has participant `id` (not the person): a head that
   *  names them, else a DM with them. Cloud answers another participant's picture only with one. */
  conversationWith(id: string): string | undefined {
    if (id === LOCAL_USER) return undefined;
    for (const [conversation, head] of this.heads) {
      const people = head.participants;
      if (
        Array.isArray(people) &&
        people.some((person) => (person as Json | null)?.id === id && (person as Json).left_at === undefined)
      )
        return conversation;
    }
    for (const [conversation, entry] of this.entries) if (entry.dm_peer === id) return conversation;
    return undefined;
  }

  /** The person's id rewritten to the page's `me` in an owner value (people, authors, cursors). */
  localize<T>(value: T): T {
    const me = this.participant;
    if (!me) return value;
    const swap = (id: unknown) => (id === me ? LOCAL_USER : id);
    const walk = (node: unknown, key?: string): unknown => {
      if (Array.isArray(node)) return node.map((item) => walk(item, key));
      if (!node || typeof node !== "object") return node;
      const result: Json = {};
      for (const [field, child] of Object.entries(node as Json)) {
        if (field === "authors" && Array.isArray(child)) {
          result[field] = child.map(swap);
        } else if (field === "read_cursors" && child && typeof child === "object") {
          result[field] = Object.fromEntries(Object.entries(child as Json).map(([id, seq]) => [swap(id), seq]));
        } else if (["author", "mention", "participant", "owner_user", "dm_peer"].includes(field)) {
          result[field] = swap(child);
        } else if (field === "id" && key === "participants") {
          result[field] = swap(child);
        } else {
          result[field] = walk(child, field);
        }
      }
      return result;
    };
    return walk(value) as T;
  }

  /** The cloud inbox, merged by the caller with the local one. Lists from the owner once per
   * connection (and after an inbox reset); later reads use the entries the events keep current. */
  async inbox(capable: boolean): Promise<HomeConversation[]> {
    if (!capable) return [];
    // A reset during a list (a sign-in) makes that list stale: list again, at most twice more.
    for (let attempt = 0; !this.listed && attempt < 3; attempt++) {
      this.listing ??= this.list().finally(() => (this.listing = null));
      await this.listing;
    }
    return [...this.entries.keys()].map((id) => this.summary(id)).filter((c): c is HomeConversation => !!c);
  }

  private async list(): Promise<void> {
    const epoch = this.epoch;
    const status = await this.daemon.request<Json>("cloud-session-status").catch(() => ({}) as Json);
    if (status.state !== "active" || typeof status.participant !== "string") {
      // Signed out (or a daemon without the person's lease): no cloud rows.
      this.participant = null;
      this.entries = new Map();
      this.heads.clear();
      this.seen.clear();
      return;
    }
    if (status.participant !== this.participant) {
      this.heads.clear();
      this.seen.clear();
    }
    this.participant = status.participant;
    // Subscribed before the list, so no inbox change falls between them.
    void this.daemon.request("cloud-inbox-subscribe").catch(() => undefined);
    const list = await this.daemon.request<{ entries?: Json[] }>("cloud-inbox-list").catch(() => null);
    if (!list) return;
    const entries = (list.entries ?? []).map((entry) => this.localize(entry)).filter(listed);
    this.entries = new Map(entries.map((entry) => [String(entry.conversation), entry]));
    for (const id of this.entries.keys()) this.known.add(id);
    this.listed = epoch === this.epoch;
    this.hydrate([...this.entries.keys()].filter((id) => !this.heads.has(id)));
  }

  /** The summary the page shows: the owner's head, with the inbox's unread, pin and mute. */
  summary(id: string): HomeConversation | undefined {
    const entry = this.entries.get(id);
    const head = this.heads.get(id);
    const base = head ? this.project(head, LOCAL_USER) : entry ? fromEntry(entry) : undefined;
    if (!base) return undefined;
    if (!entry) return { ...base, owner: "cloud" };
    return {
      ...base,
      owner: "cloud",
      title: base.title || String(entry.title ?? ""),
      lastSeq: Math.max(base.lastSeq, num(entry.last_seq)),
      updatedAt: Math.max(base.updatedAt, time(entry.last_at)),
      unread: num(entry.unread),
      mentions: num(entry.mentions),
      pinned: entry.pinned === true,
      ...(entry.pinned === true && typeof entry.pin_position === "number" ? { pinPosition: entry.pin_position } : {}),
      ...(entry.marked_unread === true ? { markedUnread: true } : {}),
      muted: mutedNow(entry),
      lastText: base.lastText ?? (String(entry.preview ?? "") || undefined),
    };
  }

  /** A page read: the head it carries is kept, and the conversation's live events start. */
  async read<T extends Json>(cmd: string, params: Json): Promise<T> {
    if (typeof params.tail === "number") params = { ...params, tail: Math.min(params.tail, MAX_TAIL) };
    const value = this.localize(await this.daemon.request<T>(cmd, params));
    const head = (value as Json).conversation as Json | undefined;
    if (head && typeof head === "object") this.keepHead(String(head.id), head);
    if (cmd === "cloud-conversation-snapshot") this.subscribe(String(params.conversation));
    return value;
  }

  /** One op as the person (`origin: "user"`), the same op shapes as the local owner. */
  async op(conversation: string, key: string, op: Json): Promise<Json> {
    const sent: Json = { ...op };
    // An owner from before threads keeps a thread reply as a reply to the root's first part.
    // A nested reply keeps its own parent.
    if (typeof op.thread_root === "string" && !op.reply_to)
      sent.reply_to = { message_id: op.thread_root, part_index: 0 };
    return this.daemon.request("cloud-conversation-op", {
      conversation,
      idempotency_key: key,
      origin: "user",
      op: sent,
    });
  }

  /** A `cloud-*` event as the page's changes; null for any other event. */
  event(event: Json): {
    message?: Json;
    conversation?: HomeConversation;
    conversations?: HomeConversation[];
    removed?: string[];
    stale?: string;
    inboxStale?: boolean;
    /** A Cloud Chief's run change (the run and the steps that changed), in the owner's shape. */
    run?: { run: Json; steps: Json[] };
    /** A Cloud Chief's live frame (`step.delta`, `run.activity`, `run.live`), in the owner's shape. */
    live?: Json;
    /** Someone typing in a cloud conversation (the owner's `conversation-typing`). */
    typing?: { conversation: string; participant: string; on: boolean };
    /** Who views a cloud conversation (the owner's `conversation-presence`), ephemeral. */
    presence?: { conversation: string; participants: { participant: string; viewing: boolean }[] };
  } | null {
    // A new lease (the app signed in or switched accounts), or the owner reset the inbox.
    if (event.event === "cloud-inbox-reset") {
      this.reset();
      return { inboxStale: true };
    }
    // Before the first list this connection does not know the person: nothing to map yet.
    if (!this.participant) return null;
    switch (event.event) {
      case "cloud-conversation-changed": {
        const id = String(event.conversation);
        const change = this.localize((event.change ?? {}) as Json);
        if ((change.kind === "message" || change.kind === "message-updated") && change.message) {
          const head = this.heads.get(id);
          const message = change.message as Json;
          if (head && num(message.seq) >= num(head.last_seq))
            this.keepHead(id, { ...head, last_seq: message.seq, last_message: message, rev: event.rev });
          return { message, conversation: this.summary(id) };
        }
        if (change.kind === "conversation" && change.conversation) this.keepHead(id, change.conversation as Json);
        if (change.kind === "read-cursor") {
          const head = this.heads.get(id);
          const cursors = { ...(head?.read_cursors as Json | undefined), [String(change.participant)]: change.seq };
          if (head) this.keepHead(id, { ...head, read_cursors: cursors });
        }
        return { conversation: this.summary(id) };
      }
      case "cloud-conversation-run-changed":
        if (!event.run || typeof event.run !== "object") return null;
        return { run: { run: this.localize(event.run as Json), steps: (event.steps as Json[] | undefined) ?? [] } };
      case "cloud-conversation-live":
        if (!event.frame || typeof event.frame !== "object") return null;
        return { live: event.frame as Json };
      case "cloud-conversation-typing":
        if (typeof event.conversation !== "string" || typeof event.participant !== "string") return null;
        return {
          typing: {
            conversation: event.conversation,
            participant: this.localize({ participant: event.participant }).participant,
            on: event.on === true,
          },
        };
      case "cloud-conversation-presence": {
        if (typeof event.conversation !== "string" || !Array.isArray(event.participants)) return null;
        const participants = (event.participants as Json[])
          .filter((p) => p && typeof p.participant === "string")
          .map((p) => ({
            participant: this.localize({ participant: p.participant }).participant as string,
            viewing: p.viewing === true,
          }));
        return { presence: { conversation: event.conversation, participants } };
      }
      case "cloud-conversation-resynced": {
        const id = String(event.conversation);
        this.keepHead(id, this.localize(event.summary as Json));
        return { stale: id, conversation: this.summary(id) };
      }
      case "cloud-inbox-changed": {
        // Applied in place: the page updates these rows and reads nothing from the cloud.
        const conversations: HomeConversation[] = [];
        const removed: string[] = [];
        for (const raw of (event.entries as Json[] | undefined) ?? []) {
          const entry = this.localize(raw);
          const id = String(entry.conversation);
          this.known.add(id);
          if (!listed(entry)) {
            this.entries.delete(id);
            removed.push(id);
            continue;
          }
          this.entries.set(id, entry);
          const summary = this.summary(id);
          if (summary) conversations.push(summary);
          if (!this.heads.has(id)) this.hydrate([id]);
        }
        return { conversations, removed };
      }
      case "cloud-subscription-state":
        // The inbox socket closed for good (the owner refused it): list again on the next read.
        if (event.scope === "inbox" && event.state === "closed") this.listed = false;
        // A conversation's socket that is not live hears no presence: its viewers go until the
        // owner's next `conversation-presence` (it sends one after each subscribe).
        if (event.scope === "conversation" && event.state !== "live" && typeof event.conversation === "string")
          return { presence: { conversation: event.conversation, participants: [] } };
        return null;
      case "cloud-session-needed":
        // The app renews the lease; the page waits for it (a relist now would only fail again).
        return null;
      default:
        return null;
    }
  }

  /** Lists the inbox again on the next read (lost events, a lease change). Keeps the person and
   * the known ids, so events and ops meanwhile still map and route. */
  reset(): void {
    this.listed = false;
    this.epoch++;
  }

  private subscribe(id: string): void {
    const at = this.subscribed.indexOf(id);
    if (at >= 0) this.subscribed.splice(at, 1);
    else
      void this.daemon.request("cloud-conversation-subscribe", { conversation: id }).catch(() => {
        // Not subscribed: the next open tries again.
        const failed = this.subscribed.indexOf(id);
        if (failed >= 0) this.subscribed.splice(failed, 1);
      });
    this.subscribed.push(id);
    while (this.subscribed.length > MAX_SUBSCRIPTIONS) {
      const oldest = this.subscribed.shift()!;
      void this.daemon.request("cloud-conversation-unsubscribe", { conversation: oldest }).catch(() => undefined);
    }
  }

  /** Reads a one-message snapshot of each entry without a head: the inbox names no people. */
  private hydrate(ids: string[]): void {
    for (const id of ids)
      if (!this.hydrating.has(id)) {
        this.hydrating.add(id);
        this.hydrationQueue.push(id);
      }
    while (this.hydrationWorkers < HYDRATION_WIDTH && this.hydrationQueue.length) {
      this.hydrationWorkers++;
      void this.hydrationWorker();
    }
  }

  private async hydrationWorker(): Promise<void> {
    try {
      for (let id = this.hydrationQueue.shift(); id; id = this.hydrationQueue.shift()) {
        const page = await this.daemon
          .request<Json>("cloud-conversation-snapshot", { conversation: id, tail: 1 })
          .catch(() => null);
        this.hydrating.delete(id);
        const head = page && (this.localize(page).conversation as Json | undefined);
        if (!head || !this.entries.has(id)) continue;
        this.keepHead(id, head);
        const summary = this.summary(id);
        if (summary) this.changed(summary);
      }
    } finally {
      this.hydrationWorkers--;
    }
  }
}

/** UserDO lists removed and archived rows too; the page shows the listed ones. */
function listed(entry: Json): boolean {
  return entry.removed !== true && entry.archived !== true;
}

/** The person's mute, until `muted_until` (Unix ms) when it has one. */
function mutedNow(entry: Json): boolean {
  return entry.muted === true && (typeof entry.muted_until !== "number" || entry.muted_until > Date.now());
}

/** A conversation known only from its inbox entry (no people yet): a DM's peer has no name yet. */
function fromEntry(entry: Json): HomeConversation {
  const at = time(entry.last_at);
  const peer = typeof entry.dm_peer === "string" ? entry.dm_peer : undefined;
  const participants: HomeParticipant[] = [{ id: LOCAL_USER, kind: "human", name: "You", chief: false }];
  if (peer) {
    // Named once its head is read; until then a Chief is "Chief" and a person has no name: an
    // id is never a name (the daemon's home-inbox rows do the same).
    const chief = entry.kind === "chief";
    participants.push({
      id: peer,
      kind: peer.startsWith("agent_") ? "agent" : "human",
      name: chief ? "Chief" : "",
      chief,
    });
  }
  return {
    id: String(entry.conversation),
    owner: "cloud",
    title: String(entry.title ?? ""),
    kind: entry.kind === "chief" ? "chief" : peer || entry.kind === "dm" ? "direct" : "group",
    participants,
    lastSeq: num(entry.last_seq),
    rev: num(entry.rev),
    updatedAt: at,
    createdAt: at,
    unread: num(entry.unread),
    mentions: num(entry.mentions),
    muted: mutedNow(entry),
    pinned: entry.pinned === true,
    ...(entry.pinned === true && typeof entry.pin_position === "number" ? { pinPosition: entry.pin_position } : {}),
    ...(entry.marked_unread === true ? { markedUnread: true } : {}),
  };
}
