// The Messages mirror page's state owner: the mirror's state (off, no access, ready, ...), the
// thread list, the open conversation and its loaded window. Everything is a projection of the
// daemon's read-only `imessage.*` ops; the page keeps no copy of its own and writes nothing.
// React reads it through `useSyncExternalStore`; tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import { mergeMessages, normalizeMessage, normalizeThread } from "./model";
import {
  ACTION_RUN,
  ImessageErrors,
  ImessageOps,
  MESSAGE_PAGE,
  THREAD_LIMIT,
  type ImessageChanged,
  type ImessageStatus,
  type Message,
  type Thread,
} from "./types";

/**
 * What the page shows: `off` (the setting is off), `not_permitted` (no Full Disk Access),
 * `missing` (no Messages database on this Mac), `error` (anything else, including a daemon that
 * does not know the ops yet), `unavailable` (no host at all), else `ready`.
 */
export type ImessagePhase = "loading" | "unavailable" | "off" | "not_permitted" | "missing" | "error" | "ready";

export interface Conversation {
  chatId: number;
  /** Oldest first. */
  messages: Message[];
  /** The first page is on its way. */
  loading: boolean;
  /** An older page is on its way. */
  loadingOlder: boolean;
  /** The last page read was full, so there may be older messages. */
  hasOlder: boolean;
  failed: boolean;
}

export interface ImessageSnapshot {
  phase: ImessagePhase;
  threads: Thread[];
  selected?: number;
  conversation?: Conversation;
  /** The host's link to the daemon; down keeps what is on screen. */
  connected: boolean;
}

export class ImessageStore {
  private snapshot: ImessageSnapshot;
  private readonly listeners = new Set<() => void>();
  private lifetime = 0;
  private generation = 0;
  private threadRead = 0;
  private conversationRead = 0;
  private stops: Array<() => void> = [];
  private started = false;

  constructor(private readonly client: PageClient | null) {
    this.snapshot = { phase: client ? "loading" : "unavailable", threads: [], connected: client !== null };
  }

  getSnapshot = (): ImessageSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  /** Hears changes, then reads the state. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.started) return;
    this.started = true;
    const lifetime = ++this.lifetime;
    try {
      const stop = await this.client.subscribe<ImessageChanged>(ImessageOps.changed, (event) => {
        if (lifetime === this.lifetime) void this.changed(event);
      });
      if (lifetime !== this.lifetime) return stop();
      this.stops.push(stop);
    } catch {
      // A daemon without the stream still answers reads; the page just does not update live.
    }
    try {
      const stop = await subscribePageStreams(this.client, {
        onConnection: (connected) => {
          if (lifetime !== this.lifetime) return;
          const was = this.snapshot.connected;
          this.set({ connected });
          if (connected && !was) void this.refresh();
        },
      });
      if (lifetime !== this.lifetime) return stop();
      this.stops.push(stop);
    } catch {
      // A host without page streams is fine.
    }
    if (lifetime === this.lifetime) await this.refresh();
  }

  stop(): void {
    ++this.lifetime;
    ++this.generation;
    this.started = false;
    for (const stop of this.stops.splice(0)) stop();
  }

  /** Reads the mirror's state, then the threads and the open conversation when it is on. */
  async refresh(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    let status: ImessageStatus;
    try {
      status = await this.client.call<ImessageStatus>(ImessageOps.status, {});
    } catch (error) {
      if (generation === this.generation) this.fail(error);
      return;
    }
    if (generation !== this.generation) return;
    const phase = statusPhase(status);
    if (phase !== "ready") {
      this.set({ phase, threads: [], selected: undefined, conversation: undefined });
      return;
    }
    await this.readThreads(generation);
    const selected = this.snapshot.selected;
    if (generation === this.generation && this.snapshot.phase === "ready" && selected !== undefined) {
      await this.readConversation(selected, this.snapshot.conversation?.chatId === selected);
    }
  }

  /** Opens a thread: its newest page of messages. */
  async select(chatId: number): Promise<void> {
    if (this.snapshot.selected === chatId && this.snapshot.conversation?.chatId === chatId) return;
    this.set({ selected: chatId });
    await this.readConversation(chatId, false);
  }

  /** Reads the page before the oldest loaded message (scrolling up). */
  async loadOlder(): Promise<void> {
    const conversation = this.snapshot.conversation;
    if (!this.client || !conversation || conversation.loading || conversation.loadingOlder || !conversation.hasOlder) {
      return;
    }
    const oldest = conversation.messages[0];
    if (!oldest) return;
    const read = ++this.conversationRead;
    this.patchConversation(conversation.chatId, { loadingOlder: true });
    try {
      const result = await this.client.call<{ messages: Message[] }>(ImessageOps.messages, {
        chat_id: conversation.chatId,
        before_rowid: oldest.rowid,
        limit: MESSAGE_PAGE,
      });
      const current = this.snapshot.conversation;
      if (!current || current.chatId !== conversation.chatId) return;
      const older = (result?.messages ?? []).map(normalizeMessage);
      this.patchConversation(conversation.chatId, {
        messages: mergeMessages(current.messages, older),
        loadingOlder: false,
        hasOlder: older.length >= MESSAGE_PAGE,
      });
    } catch {
      if (read === this.conversationRead || this.snapshot.conversation?.chatId === conversation.chatId) {
        this.patchConversation(conversation.chatId, { loadingOlder: false, hasOlder: false });
      }
    }
  }

  /** Asks the app to open System Settings at Full Disk Access (spends the click). */
  openFullDiskAccess(): Promise<void> {
    return this.quiet(ImessageOps.openFullDiskAccess, {});
  }

  /** Opens cmux Settings, where the mirror's toggle is. */
  openSettings(): Promise<void> {
    return this.quiet(ACTION_RUN, { action: "openSettings", args: { setting: "imessage.enabled" } });
  }

  private async quiet(op: string, params: unknown): Promise<void> {
    try {
      await this.client?.call(op, params);
    } catch {
      // Nothing to show: the button stays, and the page re-reads when it is visible again.
    }
  }

  /** `imessage-changed`: a state change re-reads everything; new messages re-read what they touch. */
  private async changed(event: ImessageChanged): Promise<void> {
    if (event?.resync || event?.status_changed || this.snapshot.phase !== "ready") return this.refresh();
    const touched = new Set((event?.chat_ids ?? []).map(Number));
    const generation = this.generation;
    await this.readThreads(generation);
    const open = this.snapshot.conversation;
    if (generation === this.generation && open && (touched.size === 0 || touched.has(open.chatId))) {
      await this.readConversation(open.chatId, true);
    }
  }

  private async readThreads(generation: number): Promise<void> {
    if (!this.client) return;
    const read = ++this.threadRead;
    try {
      const result = await this.client.call<{ threads: Thread[] }>(ImessageOps.threads, { limit: THREAD_LIMIT });
      if (generation !== this.generation || read !== this.threadRead) return;
      const threads = (result?.threads ?? []).map(normalizeThread);
      const kept = threads.some((thread) => thread.chat_id === this.snapshot.selected) ? this.snapshot.selected : undefined;
      const selected = kept ?? threads[0]?.chat_id;
      const conversation = this.snapshot.conversation?.chatId === selected ? this.snapshot.conversation : undefined;
      this.set({ phase: "ready", threads, selected, conversation });
    } catch (error) {
      if (generation === this.generation && read === this.threadRead) this.fail(error);
    }
  }

  /**
   * Reads the newest page of `chatId`. `keep` merges it into the loaded window (a live update or a
   * refresh), so older pages already read stay and the scroll position holds.
   */
  private async readConversation(chatId: number, keep: boolean): Promise<void> {
    if (!this.client) return;
    const read = ++this.conversationRead;
    const current = this.snapshot.conversation;
    if (!keep || current?.chatId !== chatId) {
      this.set({
        conversation: { chatId, messages: [], loading: true, loadingOlder: false, hasOlder: false, failed: false },
      });
    }
    try {
      const result = await this.client.call<{ messages: Message[] }>(ImessageOps.messages, {
        chat_id: chatId,
        limit: MESSAGE_PAGE,
      });
      const now = this.snapshot.conversation;
      if (read !== this.conversationRead || !now || now.chatId !== chatId) return;
      const fresh = (result?.messages ?? []).map(normalizeMessage);
      const merged = keep ? mergeMessages(now.messages, fresh) : fresh;
      this.patchConversation(chatId, {
        messages: merged,
        loading: false,
        failed: false,
        // A live merge keeps what paging already learned; a first read learns it from its size.
        hasOlder: keep && now.messages.length > 0 ? now.hasOlder : fresh.length >= MESSAGE_PAGE,
      });
    } catch (error) {
      if (read !== this.conversationRead || this.snapshot.conversation?.chatId !== chatId) return;
      const phase = errorPhase(error);
      if (phase !== "error") return this.fail(error);
      this.patchConversation(chatId, { loading: false, failed: true });
    }
  }

  private fail(error: unknown): void {
    if (isPageError(error) && error.code === LINK_CLOSED) {
      this.set({ connected: false, phase: this.snapshot.phase === "loading" ? "error" : this.snapshot.phase });
      return;
    }
    const phase = errorPhase(error);
    this.set({ phase, ...(phase === "ready" ? {} : { threads: [], selected: undefined, conversation: undefined }) });
  }

  private patchConversation(chatId: number, patch: Partial<Conversation>): void {
    const conversation = this.snapshot.conversation;
    if (!conversation || conversation.chatId !== chatId) return;
    this.set({ conversation: { ...conversation, ...patch } });
  }

  private set(patch: Partial<ImessageSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** The page state a status answer means. */
export function statusPhase(status: ImessageStatus | null | undefined): ImessagePhase {
  if (!status || typeof status !== "object") return "error";
  if (status.enabled !== true || status.access === "off") return "off";
  switch (status.access) {
    case "ok":
      return "ready";
    case "not_permitted":
      return "not_permitted";
    case "missing":
      return "missing";
    default:
      return "error";
  }
}

/** The page state a list op's refusal means; any other failure (an unknown op too) is `error`. */
export function errorPhase(error: unknown): ImessagePhase {
  if (!isPageError(error)) return "error";
  const code = error.code.startsWith("cmux.") ? error.code.slice("cmux.".length) : error.code;
  if (code === ImessageErrors.disabled) return "off";
  if (code === ImessageErrors.notPermitted) return "not_permitted";
  return "error";
}
