// The channels Home's view state: the inbox rows, the selected conversation's message window, the
// open thread and typing. All data comes from the host's `cmux.home.*` ops over the same Home
// owners the native Home reads; the page keeps only a bounded window (WINDOW messages of the open
// conversation, pages of PAGE older ones on demand) and refetches on a gap. Writes go to the host
// with an idempotency key; the owner's event is what shows them.
import { isPageError, type PageClient } from "../shared/pageClient";
import { subscribePageStreams } from "../shared/pageStreams";
import { mergeMessages } from "./model";
import {
  HomeOps,
  type HomeConversation,
  type HomeEventBatch,
  type HomeInbox,
  type HomeMessage,
  type HomePage,
  type HomeParticipant,
} from "./types";

export const PAGE = 100;
export const WINDOW = 1500;

export type Connection = "connecting" | "online" | "offline";

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
  /** Participant ids typing in the open conversation. */
  typing: readonly string[];
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

  constructor(private readonly client: PageClient | null) {
    this.snapshot = {
      connection: client ? "connecting" : "offline",
      loading: client !== null,
      conversations: new Map(),
      messages: [],
      hasOlder: false,
      loadingOlder: false,
      typing: [],
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
    this.set({ selected: id, messages: [], hasOlder: false, thread: undefined, typing: [] });
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
      this.set({ conversations, messages, hasOlder: (messages[0]?.seq ?? 1) > 1 });
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
      const older = await this.client.call<{ messages: HomeMessage[] }>(HomeOps.history, {
        conversation: selected,
        beforeSeq: before,
        limit: PAGE,
      });
      if (this.snapshot.selected !== selected) return;
      const merged = mergeMessages(this.snapshot.messages, older.messages, this.snapshot.messages.length + PAGE);
      this.set({ messages: merged, hasOlder: older.messages.length === PAGE && (merged[0]?.seq ?? 1) > 1 });
    } catch (error) {
      this.set({ error: describe(error) });
    } finally {
      this.set({ loadingOlder: false });
    }
  }

  openThread(root: string | undefined): void {
    this.set({ thread: root });
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

  async react(message: HomeMessage, value: string): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(HomeOps.react, {
        conversation: message.conversation,
        message: message.id,
        partIndex: 0,
        value,
        idempotencyKey: this.key("react"),
      });
    } catch (error) {
      this.set({ error: describe(error) });
    }
  }

  dismissError(): void {
    this.set({ error: undefined });
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
    if (batch.typing && selected) {
      const typing = new Set(this.snapshot.typing);
      for (const entry of batch.typing) {
        if (entry.conversation !== selected) continue;
        if (entry.on) typing.add(entry.participant);
        else typing.delete(entry.participant);
      }
      patch.typing = [...typing];
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

/** The Chief DM first, else the newest conversation. */
function defaultSelection(conversations: readonly HomeConversation[]): string | undefined {
  const chief = conversations.find((c) => c.kind === "chief");
  if (chief) return chief.id;
  return [...conversations].sort((a, b) => b.updatedAt - a.updatedAt)[0]?.id;
}
