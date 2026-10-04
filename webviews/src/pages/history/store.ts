// The History page's state owner on the page side: query state, the loaded window of entries, and
// the intents it sends. Entries are a projection of the provider (`cmux.history.entries.list`);
// the page keeps no optimistic copy: a remove or clear re-reads after the provider confirms.
// React reads it through `useSyncExternalStore` (no effects); tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  filterKinds,
  groupEntries,
  PAGE_LIMIT,
  reconcileSelection,
  siteHost,
  type HistoryFilter,
  type HistoryGroup,
  type HistoryGrouping,
} from "./model";
import {
  ACTION_RUN,
  CLIPBOARD_WRITE,
  HistoryOps,
  type HistoryChanged,
  type HistoryEntry,
  type HistoryListParams,
  type HistoryListResult,
  type HistoryRange,
} from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export interface HistorySnapshot {
  text: string;
  filter: HistoryFilter;
  grouping: HistoryGrouping;
  entries: HistoryEntry[];
  groups: HistoryGroup[];
  selection?: string;
  /** True until the first reply for the current query arrives. */
  loading: boolean;
  connection: Connection;
  /** The last failed intent's message, cleared by the next success. */
  error?: string;
}

export interface HistoryStoreOptions {
  /** The pasteboard write the page can do itself; falls back to the host op when it rejects. */
  writeClipboard?: (text: string) => Promise<void>;
  newKey?: () => string;
}

export class HistoryStore {
  private snapshot: HistorySnapshot;
  private readonly listeners = new Set<() => void>();
  private generation = 0;
  private unsubscribe?: () => void;
  private starting = false;

  constructor(
    private readonly client: PageClient | null,
    private readonly options: HistoryStoreOptions = {},
  ) {
    this.snapshot = {
      text: "",
      filter: "all",
      grouping: "day",
      entries: [],
      groups: [],
      loading: client !== null,
      connection: client ? "connecting" : "disconnected",
    };
  }

  getSnapshot = (): HistorySnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Subscribes to changes and loads the first window. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.unsubscribe || this.starting) return;
    this.starting = true;
    try {
      const unsubscribe = await this.client.subscribe<HistoryChanged>(HistoryOps.changed, () => void this.reload());
      if (this.listeners.size === 0 && !this.starting) {
        unsubscribe();
        return;
      }
      this.unsubscribe = unsubscribe;
    } catch (error) {
      this.set({ connection: "disconnected", loading: false, error: message(error) });
      return;
    } finally {
      this.starting = false;
    }
    await this.reload();
  }

  stop(): void {
    this.starting = false;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
  }

  setText(text: string): void {
    if (text === this.snapshot.text) return;
    this.set({ text });
    void this.reload();
  }

  setFilter(filter: HistoryFilter): void {
    if (filter === this.snapshot.filter) return;
    this.set({ filter });
    void this.reload();
  }

  setGrouping(grouping: HistoryGrouping): void {
    if (grouping === this.snapshot.grouping) return;
    this.set({ grouping, groups: groupEntries(this.snapshot.entries, grouping) });
  }

  select(selection: string | undefined): void {
    if (selection !== this.snapshot.selection) this.set({ selection });
  }

  /** Re-reads the current query; an older reply that arrives late is dropped. */
  async reload(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    const { text, filter } = this.snapshot;
    const params: HistoryListParams = { kinds: filterKinds(filter), text, limit: PAGE_LIMIT };
    if (!this.snapshot.loading) this.set({ loading: true });
    try {
      const result = await this.client.call<HistoryListResult>(HistoryOps.list, params);
      if (generation !== this.generation) return;
      const entries = result.entries;
      this.set({
        entries,
        groups: groupEntries(entries, this.snapshot.grouping),
        selection: reconcileSelection(entries, this.snapshot.selection),
        loading: false,
        connection: "connected",
        error: undefined,
      });
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
    }
  }

  /** Runs the row's restore action in the app (page open, go to, reopen, resume, run again). */
  open(entry: HistoryEntry, newTab = false): Promise<void> {
    return this.intent(ACTION_RUN, { action: "history.open", args: { id: entry.id, new_tab: newTab } }, false);
  }

  remove(entry: HistoryEntry): Promise<void> {
    return this.intent(HistoryOps.remove, { ids: [entry.id], idempotency_key: this.key() });
  }

  removeSite(entry: HistoryEntry): Promise<void> {
    const host = siteHost(entry);
    if (!host) return Promise.resolve();
    return this.intent(HistoryOps.removeSite, { host, profile: entry.profile, idempotency_key: this.key() });
  }

  clear(range: HistoryRange): Promise<void> {
    return this.intent(HistoryOps.clear, { range, idempotency_key: this.key() });
  }

  async copy(text: string): Promise<void> {
    try {
      if (!this.options.writeClipboard) throw new Error("no page clipboard");
      await this.options.writeClipboard(text);
    } catch {
      await this.intent(CLIPBOARD_WRITE, { text }, false);
    }
  }

  private async intent(op: string, params: unknown, reread = true): Promise<void> {
    if (!this.client) return;
    try {
      await this.client.call(op, params);
      if (this.snapshot.error) this.set({ error: undefined });
    } catch (error) {
      this.set(failure(error));
      return;
    }
    // The provider also emits `cmux.history.changed`; re-reading here keeps the page correct when
    // the event is late, and the generation check drops the duplicate reply.
    if (reread) await this.reload();
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<HistorySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function failure(error: unknown): Partial<HistorySnapshot> {
  if (isPageError(error) && error.code === "cmux.protocol.transport") {
    return { connection: "disconnected", error: error.message };
  }
  return { error: message(error) };
}
