// The channels Home's view state: the inbox rows, the selected conversation's message window, the
// open thread and typing. All data comes from the host's `cmux.home.*` ops over the same Home
// owners the native Home reads; the page keeps only a bounded window (WINDOW messages of the open
// conversation, pages of PAGE older ones on demand) and refetches on a gap. Writes go to the host
// with an idempotency key; the owner's event is what shows them.
import { isPageError, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { DraftBook, type HomeDraft } from "./drafts";
import { mergeMessages, threadOf } from "./model";
import {
  HomeOps,
  type HomeConversation,
  type HomeEventBatch,
  type HomeHistory,
  type HomeInbox,
  type HomeMessage,
  type HomePage,
  type HomeParticipant,
  type HomeThreadPage,
  type HomeThreadStats,
} from "./types";

export const PAGE = 100;
export const WINDOW = 1500;

export type Connection = "connecting" | "online" | "offline";

/** The open thread as the owner's thread read returned it (`cmux.home.thread`), kept current by
 * events. Absent on a host without the read: the panel shows the window's replies. */
export interface ThreadView {
  root: string;
  /** The root and the loaded replies, ascending by seq. */
  messages: readonly HomeMessage[];
  /** More replies follow the last loaded one. */
  hasMore: boolean;
  loading: boolean;
}

export interface HomeSnapshot {
  connection: Connection;
  loading: boolean;
  me?: HomeParticipant;
  conversations: ReadonlyMap<string, HomeConversation>;
  selected?: string;
  /** The open conversation's window, ascending by seq. */
  messages: readonly HomeMessage[];
  /** Older messages exist before the window's first seq. */
  hasOlder: boolean;
  loadingOlder: boolean;
  thread?: string;
  /** The open thread's owner read (root and every reply page loaded so far). */
  threadView?: ThreadView;
  /** The owner's stats of thread roots (from pages, history and thread reads), by root id. */
  threadStats: ReadonlyMap<string, HomeThreadStats>;
  /** Participant ids typing in the open conversation. */
  typing: readonly string[];
  /** What showed as new when the conversation opened: messages after my read cursor (`after`) up
   * to the newest one then (`through`). Messages that arrive while it is open are read live. */
  unseen?: { after: number; through: number };
  /** Threads opened in this visit: their new replies are read. */
  threadsSeen: ReadonlySet<string>;
  /** The open conversation's running agent reply (shown until the reply posts). */
  draft?: HomeDraft;
  error?: string;
}

const describe = (error: unknown) => (isPageError(error) || error instanceof Error ? error.message : String(error));

export class HomeChannelsStore {
  private snapshot: HomeSnapshot;
  private readonly listeners = new Set<() => void>();
  private stops: Array<() => void> = [];
  private starting?: Promise<void>;
  private generation = 0;
  private nextKey = 0;
  /** The read cursor this page last sent per conversation (one read per new seq). */
  private readonly readSeq = new Map<string, number>();
  private readonly drafts = new DraftBook();

  constructor(private readonly client: PageClient | null) {
    this.snapshot = {
      connection: client ? "connecting" : "offline",
      loading: client !== null,
      conversations: new Map(),
      messages: [],
      hasOlder: false,
      loadingOlder: false,
      typing: [],
      threadsSeen: new Set(),
      threadStats: new Map(),
    };
  }

  getSnapshot = (): HomeSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  start(): Promise<void> {
    if (!this.client) return Promise.resolve();
    this.starting ??= this.begin(this.client);
    return this.starting;
  }

  private async begin(client: PageClient): Promise<void> {
    try {
      this.stops.push(
        await subscribePageStreams(client, {
          onConnection: (connected) => {
            if (!connected) this.set({ connection: "offline" });
            else if (this.snapshot.connection === "offline") void this.reloadInbox();
          },
        }),
      );
      this.stops.push(await client.subscribe<HomeEventBatch>(HomeOps.events, (batch) => this.apply(batch)));
      // Replies that came while the page was hidden are read once the person sees them.
      const shown = () => {
        if (document.visibilityState === "visible") this.readOpen();
      };
      document.addEventListener("visibilitychange", shown);
      this.stops.push(() => document.removeEventListener("visibilitychange", shown));
    } catch (error) {
      this.set({ error: describe(error), loading: false });
    }
    await this.reloadInbox();
  }

  private stop(): void {
    for (const stop of this.stops) stop();
    this.stops = [];
    this.starting = undefined;
  }

  async reloadInbox(): Promise<void> {
    if (!this.client) return;
    try {
      const inbox = await this.client.call<HomeInbox>(HomeOps.inbox, {});
      const conversations = new Map(inbox.conversations.map((c) => [c.id, c]));
      const selected =
        this.snapshot.selected && conversations.has(this.snapshot.selected)
          ? this.snapshot.selected
          : defaultSelection(inbox.conversations);
      this.set({ me: inbox.me, conversations, connection: "online", loading: false, error: undefined });
      if (selected && selected !== this.snapshot.selected) await this.select(selected);
      else if (selected) await this.reloadPage(selected);
    } catch (error) {
      this.set({ error: describe(error), loading: false });
    }
  }

  /** Opens a conversation: its newest page, then marks it read. */
  async select(id: string): Promise<void> {
    if (id === this.snapshot.selected && this.snapshot.messages.length > 0) return;
    this.set({
      selected: id,
      messages: [],
      hasOlder: false,
      thread: undefined,
      threadView: undefined,
      threadStats: new Map(),
      typing: [],
      unseen: undefined,
      threadsSeen: new Set(),
      draft: this.drafts.draft(id),
    });
    await this.reloadPage(id);
  }

  private async reloadPage(id: string): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const page = await this.client.call<HomePage>(HomeOps.page, { conversation: id, tail: PAGE });
      if (generation !== this.generation || this.snapshot.selected !== id) return;
      const conversations = new Map(this.snapshot.conversations).set(id, page.conversation);
      // Keep what events merged while the page was in flight (and older pages already read);
      // the snapshot wins for a message both have unless the event copy was edited later.
      const kept = this.snapshot.messages.filter((m) => m.conversation === id);
      const fresh = page.messages.map((m) => {
        const event = kept.find((k) => k.seq === m.seq);
        return event && (event.editedAt ?? 0) > (m.editedAt ?? 0) ? event : m;
      });
      const messages = mergeMessages(kept, fresh, WINDOW);
      const unseen = this.snapshot.unseen ?? {
        after: page.conversation.lastSeq - page.conversation.unread,
        through: page.conversation.lastSeq,
      };
      // A reply that came in with this page (not as an event: a gap, a large batch) ends its draft.
      const live = this.drafts.draft(id);
      const reply = live && messages.find((m) => m.clientMessageId === live.turn && m.author === live.participant);
      if (reply) this.drafts.posted(reply);
      this.set({
        conversations,
        messages,
        hasOlder: (messages[0]?.seq ?? 1) > 1,
        unseen,
        draft: this.drafts.draft(id),
        threadStats: withStats(this.snapshot.threadStats, page.threads),
      });
      this.markRead(page.conversation, messages.at(-1)?.seq ?? 0);
    } catch (error) {
      if (generation === this.generation) this.set({ error: describe(error) });
    }
  }

  /** One page of older messages before the window (scrolling to the top). */
  async loadOlder(): Promise<void> {
    const { selected, messages, hasOlder, loadingOlder } = this.snapshot;
    if (!this.client || !selected || !hasOlder || loadingOlder) return;
    const before = messages[0]?.seq ?? 1;
    this.set({ loadingOlder: true });
    try {
      const older = await this.client.call<HomeHistory>(HomeOps.history, {
        conversation: selected,
        beforeSeq: before,
        limit: PAGE,
      });
      if (this.snapshot.selected !== selected) return;
      const merged = mergeMessages(this.snapshot.messages, older.messages, this.snapshot.messages.length + PAGE);
      this.set({
        messages: merged,
        hasOlder: older.messages.length === PAGE && (merged[0]?.seq ?? 1) > 1,
        threadStats: withStats(this.snapshot.threadStats, older.threads),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    } finally {
      this.set({ loadingOlder: false });
    }
  }

  openThread(root: string | undefined): void {
    const threadView = root ? { root, messages: [], hasMore: false, loading: true } : undefined;
    if (!root || this.snapshot.threadsSeen.has(root)) this.set({ thread: root, threadView });
    else this.set({ thread: root, threadView, threadsSeen: new Set(this.snapshot.threadsSeen).add(root) });
    if (root) void this.loadThread(root, 0);
  }

  /** The next page of the open thread's replies (the owner's thread read). */
  loadMoreReplies(): void {
    const view = this.snapshot.threadView;
    if (!view || view.loading || !view.hasMore) return;
    this.set({ threadView: { ...view, loading: true } });
    void this.loadThread(view.root, view.messages.at(-1)?.seq ?? 0);
  }

  private async loadThread(root: string, afterSeq: number): Promise<void> {
    const conversation = this.snapshot.selected;
    if (!this.client || !conversation) return;
    const current = () => this.snapshot.selected === conversation && this.snapshot.threadView?.root === root;
    try {
      const page = await this.client.call<HomeThreadPage>(HomeOps.thread, {
        conversation,
        root,
        afterSeq,
        limit: PAGE,
      });
      if (!current()) return;
      const view = this.snapshot.threadView!;
      const messages = mergeMessages(view.messages, [page.root, ...page.replies], Number.MAX_SAFE_INTEGER);
      this.set({
        threadView: { root, messages, hasMore: page.hasMore, loading: false },
        threadStats: withStats(this.snapshot.threadStats, [page.thread]),
      });
    } catch (error) {
      if (!current()) return;
      // A host without the read: the panel shows the window's replies (no view).
      const unknown = isPageError(error) && error.code === "cmux.protocol.unknown_op";
      this.set({ threadView: undefined, ...(unknown ? {} : { error: describe(error) }) });
    }
  }

  /** Sends text to the open conversation (or the open thread). The owner's event shows it. */
  async send(text: string, thread?: string): Promise<boolean> {
    const conversation = this.snapshot.selected;
    const trimmed = text.trim();
    if (!this.client || !conversation || !trimmed) return false;
    try {
      await this.client.call(HomeOps.send, {
        conversation,
        text: trimmed,
        threadRoot: thread,
        idempotencyKey: this.key("send"),
      });
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Creates a channel (a titled group) with these members and opens it. Resolves true when the
   * owner created it. */
  async createChannel(title: string, participants: readonly string[]): Promise<boolean> {
    const name = title.trim();
    if (!this.client || !name || participants.length === 0) return false;
    try {
      const result = await this.client.call<{ conversation?: string }>(HomeOps.createGroup, {
        title: name,
        participants,
        idempotencyKey: this.key("create"),
      });
      await this.reloadInbox();
      if (result.conversation) await this.select(result.conversation);
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Adds my reaction, or takes it back when I already reacted with it. */
  async react(message: HomeMessage, value: string): Promise<void> {
    if (!this.client) return;
    const mine = message.reactions.find((r) => r.value === value && r.author === this.snapshot.me?.id);
    try {
      await this.client.call(HomeOps.react, {
        conversation: message.conversation,
        message: message.id,
        partIndex: mine?.partIndex ?? 0,
        value,
        tapback: mine?.tapback,
        remove: mine !== undefined,
        idempotencyKey: this.key("react"),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    }
  }

  /** Replaces my message's text. Resolves true when the owner took it. */
  async edit(message: HomeMessage, text: string): Promise<boolean> {
    const trimmed = text.trim();
    if (!this.client || !trimmed) return false;
    try {
      await this.client.call(HomeOps.edit, {
        conversation: message.conversation,
        message: message.id,
        text: trimmed,
        idempotencyKey: this.key("edit"),
      });
      return true;
    } catch (error) {
      this.set({ error: describe(error) });
      return false;
    }
  }

  /** Deletes my message for everyone (the owner keeps a "deleted" row). */
  async retract(message: HomeMessage): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(HomeOps.retract, {
        conversation: message.conversation,
        message: message.id,
        idempotencyKey: this.key("retract"),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    }
  }

  dismissError(): void {
    this.set({ error: undefined });
  }

  /** Reads the open conversation through its newest loaded message. */
  private readOpen(): void {
    const { selected, messages } = this.snapshot;
    const open = selected ? this.snapshot.conversations.get(selected) : undefined;
    if (open) this.markRead(open, messages.at(-1)?.seq ?? 0);
  }

  /** Moves my read cursor to the newest seq I have seen, once per new seq. */
  private markRead(conversation: HomeConversation, seen: number): void {
    const seq = Math.max(conversation.lastSeq, seen);
    const cursor = Math.max(conversation.lastSeq - conversation.unread, this.readSeq.get(conversation.id) ?? 0);
    if (!this.client || seq <= cursor) return;
    this.readSeq.set(conversation.id, seq);
    void this.client
      .call(HomeOps.read, { conversation: conversation.id, seq, idempotencyKey: this.key("read") })
      .catch(() => this.readSeq.delete(conversation.id));
  }

  /** Applies one coalesced host batch. */
  private apply(batch: HomeEventBatch): void {
    const patch: Partial<HomeSnapshot> = {};
    if (batch.connection) patch.connection = batch.connection;
    // Typing is ephemeral: a reconnect or an inbox refetch ends every indicator.
    if (batch.connection || batch.inboxStale) patch.typing = [];
    if (batch.connection === "offline") this.drafts.clear();
    // Drafts first, then typing off and the posted messages: a reply that posts in the same
    // batch as its last draft item ends the draft, and a late item cannot bring it back.
    for (const item of batch.drafts ?? []) this.drafts.apply(item);
    for (const entry of batch.typing ?? []) if (!entry.on) this.drafts.typingOff(entry.conversation, entry.participant);
    for (const message of batch.messages ?? []) this.drafts.posted(message);
    let conversations: Map<string, HomeConversation> | undefined;
    for (const conversation of batch.conversations ?? []) {
      conversations ??= new Map(this.snapshot.conversations);
      conversations.set(conversation.id, conversation);
    }
    for (const id of batch.removed ?? []) {
      conversations ??= new Map(this.snapshot.conversations);
      conversations.delete(id);
    }
    if (conversations) patch.conversations = conversations;
    const selected = this.snapshot.selected;
    const incoming = (batch.messages ?? []).filter((message) => message.conversation === selected);
    if (incoming.length > 0) patch.messages = mergeMessages(this.snapshot.messages, incoming, WINDOW);
    // The open thread's view takes its root and replies from events too (a reply, an edit).
    const view = this.snapshot.threadView;
    const threadIncoming = view ? incoming.filter((m) => m.id === view.root || threadOf(m) === view.root) : [];
    if (view && threadIncoming.length > 0) {
      // Only what follows the loaded pages: a reply between pages comes with the next page.
      const tail = view.hasMore
        ? threadIncoming.filter((m) => view.messages.some((k) => k.seq === m.seq))
        : threadIncoming;
      patch.threadView = { ...view, messages: mergeMessages(view.messages, tail, Number.MAX_SAFE_INTEGER) };
    }
    if (batch.typing && selected) {
      const typing = new Set(this.snapshot.typing);
      for (const entry of batch.typing) {
        if (entry.conversation !== selected) continue;
        if (entry.on) typing.add(entry.participant);
        else typing.delete(entry.participant);
      }
      patch.typing = [...typing];
    }
    if (selected) {
      const draft = this.drafts.draft(selected);
      if (draft?.text !== this.snapshot.draft?.text || draft?.turn !== this.snapshot.draft?.turn) patch.draft = draft;
    }
    this.set(patch);
    const open = selected ? this.snapshot.conversations.get(selected) : undefined;
    if (open && incoming.length > 0 && document.visibilityState === "visible") {
      this.markRead(open, Math.max(...incoming.map((m) => m.seq)));
    }
    if (batch.inboxStale) void this.reloadInbox();
    else if (selected && batch.stale?.includes(selected)) void this.reloadPage(selected);
  }

  private key(kind: string): string {
    return `home-channels-${kind}-${Date.now().toString(36)}-${(this.nextKey++).toString(36)}`;
  }

  private set(patch: Partial<HomeSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** The stats map with these owner stats replacing the roots they name. */
function withStats(
  current: ReadonlyMap<string, HomeThreadStats>,
  stats: readonly HomeThreadStats[] | undefined,
): ReadonlyMap<string, HomeThreadStats> {
  if (!stats || stats.length === 0) return current;
  const next = new Map(current);
  for (const entry of stats) next.set(entry.root, entry);
  return next;
}

/** The Chief DM first, else the newest conversation. */
function defaultSelection(conversations: readonly HomeConversation[]): string | undefined {
  const chief = conversations.find((c) => c.kind === "chief");
  if (chief) return chief.id;
  return [...conversations].sort((a, b) => b.updatedAt - a.updatedAt)[0]?.id;
}
