// The History page's state owner on the page side: query state, the loaded window of entries, and
// the intents it sends. Entries are a projection of the provider (`cmux.history.entries.list`);
// the page keeps no optimistic copy: a remove or clear re-reads after the provider confirms.
// React reads it through `useSyncExternalStore` (no effects); tests drive it directly.
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
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
  type CookieBackup,
  type CookieBackupsDeleted,
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
  /** The last reply was not the whole list (`pending_kinds`): the page says so and asks again by itself. */
  pending: boolean;
  connection: Connection;
  /** The last failed intent's message, cleared by the next success. */
  error?: string;
  /** The Cookie Backups panel: open, and its rows once read (newest first). */
  cookieBackups: { open: boolean; loading: boolean; backups: CookieBackup[]; error?: string };
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
  private unpage?: () => void;
  private starting = false;
  private subscribingChanges = false;
  /** A reconnect came while a subscribe was pending: follow again once it settles. */
  private refollowQueued = false;
  /** Counts the owner link's returns; a subscribe from before the last one is for the lost link. */
  private linkEpoch = 0;
  private changesUnsupported = false;
  private lifetime = 0;
  /** The one timer that reads a list that is not complete again; never a second one. */
  private pendingTimer?: ReturnType<typeof setTimeout>;
  /** How many timed re-reads the current not-complete list has had: the wait backs off with it. */
  private pendingAttempt = 0;
  /** Ends the wait for a hidden page to show again (its `visibilitychange` listener). */
  private unshown?: () => void;

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
      pending: false,
      connection: client ? "connecting" : "disconnected",
      cookieBackups: { open: false, loading: false, backups: [] },
    };
  }

  private backupsGeneration = 0;

  /** Opens the Cookie Backups panel and reads its rows. */
  showCookieBackups(): Promise<void> {
    this.set({ cookieBackups: { ...this.snapshot.cookieBackups, open: true } });
    return this.readCookieBackups();
  }

  hideCookieBackups(): void {
    ++this.backupsGeneration;
    this.set({ cookieBackups: { open: false, loading: false, backups: [] } });
  }

  /** Reads the backups; an older read that lost to a newer one (a delete starts one) is dropped. */
  private async readCookieBackups(): Promise<void> {
    if (!this.client) return;
    const generation = ++this.backupsGeneration;
    this.set({ cookieBackups: { ...this.snapshot.cookieBackups, loading: true } });
    try {
      const result = await this.client.call<{ backups: CookieBackup[] }>(HistoryOps.cookieBackupsList, {});
      if (generation !== this.backupsGeneration) return;
      const backups = (result?.backups ?? []).map((backup) => ({
        ...backup,
        created_at_ms: Number(backup.created_at_ms),
      }));
      this.set({ cookieBackups: { open: true, loading: false, backups } });
    } catch (error) {
      if (generation !== this.backupsGeneration) return;
      this.set({ cookieBackups: { ...this.snapshot.cookieBackups, loading: false, error: message(error) } });
    }
  }

  /** Deletes backups for good: the app asks the person first (an agent can no longer undo those
   * clears); a cancelled question changes nothing. */
  async deleteCookieBackups(ids: string[]): Promise<void> {
    if (!this.client || ids.length === 0) return;
    try {
      const result = await this.client.call<CookieBackupsDeleted>(HistoryOps.cookieBackupsDelete, { ids });
      if (!result?.confirmed || !this.snapshot.cookieBackups.open) return;
    } catch (error) {
      this.set({ cookieBackups: { ...this.snapshot.cookieBackups, error: message(error) } });
      return;
    }
    await this.readCookieBackups();
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

  /** Follows the owner link, then history changes, then loads the first window. Idempotent. The
   * link comes first so a change stream that fails now is asked for again on the next reconnect. */
  async start(): Promise<void> {
    if (!this.client || this.unsubscribe || this.unpage || this.starting) return;
    const lifetime = ++this.lifetime;
    const alive = () => lifetime === this.lifetime;
    this.starting = true;
    try {
      try {
        const unpage = await subscribePageStreams(this.client, {
          onConnection: (connected) => {
            if (alive()) this.onConnection(connected, alive);
          },
        });
        if (!alive()) {
          unpage();
          return;
        }
        this.unpage = unpage;
      } catch (error) {
        if (!alive()) return;
        this.set(failure(error));
      }
      // The entries do not wait on the change stream: the list is the app's read model (its own log,
      // every machine's commands), which can answer while the local daemon's stream is down.
      if (alive()) await this.followChanges(alive);
      if (alive()) await this.reload();
    } finally {
      if (alive()) this.starting = false;
    }
  }

  stop(): void {
    ++this.lifetime;
    ++this.generation;
    this.starting = false;
    this.subscribingChanges = false;
    this.refollowQueued = false;
    this.changesUnsupported = false;
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.unpage?.();
    this.unpage = undefined;
    this.clearPending();
  }

  /** A list that is not complete (`pending_kinds`) is read again by itself: after 1 s, 2 s, 4 s, then
   * each 8 s, on one timer, until a reply is complete. `history-changed` only makes a read sooner
   * (the owner emits it when an entry changes, not when its list becomes complete), so it neither
   * adds a timer nor starts the waits again. A hidden page does not read on the timer: it reads
   * once when it shows again. */
  private followPending(pending: boolean): void {
    if (!pending) {
      this.clearPending();
      return;
    }
    if (this.pendingTimer !== undefined || this.unshown) return;
    const wait = PENDING_WAITS_MS[Math.min(this.pendingAttempt, PENDING_WAITS_MS.length - 1)];
    this.pendingAttempt += 1;
    this.pendingTimer = setTimeout(() => {
      this.pendingTimer = undefined;
      if (typeof document !== "undefined" && document.visibilityState === "hidden") {
        const shown = () => {
          if (document.visibilityState === "hidden") return;
          this.unshown?.();
          void this.reload();
        };
        document.addEventListener("visibilitychange", shown);
        this.unshown = () => {
          document.removeEventListener("visibilitychange", shown);
          this.unshown = undefined;
        };
        return;
      }
      void this.reload();
    }, wait);
  }

  private clearPending(): void {
    if (this.pendingTimer !== undefined) clearTimeout(this.pendingTimer);
    this.pendingTimer = undefined;
    this.unshown?.();
    this.pendingAttempt = 0;
  }

  /** Subscribes to `history-changed` unless it already is; true when it follows them (subscribed,
   * or an owner without the stream). A failure shows the disconnected state until a read answers;
   * the next reconnect asks again. */
  private async followChanges(alive: () => boolean): Promise<boolean> {
    if (!this.client) return false;
    if (this.unsubscribe || this.changesUnsupported) return true;
    if (this.subscribingChanges) {
      this.refollowQueued = true;
      return false;
    }
    this.subscribingChanges = true;
    const epoch = this.linkEpoch;
    try {
      const unsubscribe = await this.client.subscribe<HistoryChanged>(HistoryOps.changed, () => {
        if (alive()) void this.reload();
      });
      if (!alive()) {
        unsubscribe();
        return false;
      }
      // The link went down and came back while this was pending: the queued follow asks again.
      if (epoch !== this.linkEpoch) {
        unsubscribe();
        return false;
      }
      this.unsubscribe = unsubscribe;
      return true;
    } catch (error) {
      if (!alive() || epoch !== this.linkEpoch) return false;
      // Older owners without a change stream can still answer reads.
      if (isPageError(error) && error.code === "cmux.protocol.unknown_op") {
        this.changesUnsupported = true;
        return true;
      }
      this.set({ connection: "disconnected", loading: false, error: message(error) });
      return false;
    } finally {
      if (alive()) {
        this.subscribingChanges = false;
        // A reconnect that came while this was pending asked for a fresh stream; if this one
        // failed (or belonged to the lost link), nothing else would ask again.
        if (this.refollowQueued) {
          this.refollowQueued = false;
          queueMicrotask(() => this.refollow(alive));
        }
      }
    }
  }

  /** Follows the changes, then re-reads. */
  private refollow(alive: () => boolean): void {
    if (!alive()) return;
    void (async () => {
      await this.followChanges(alive);
      if (alive()) await this.reload();
    })();
  }

  /** The host reports the owner link: down shows the disconnected state; back up (or up with no
   * change stream yet) follows the changes again, then re-reads. */
  private onConnection(connected: boolean, alive: () => boolean): void {
    if (!connected) {
      // No owner to ask: the reads stop, and the reconnect's read says again whether the list is complete.
      this.clearPending();
      this.set({ connection: "disconnected", loading: false, pending: false });
      return;
    }
    const wasDown = this.snapshot.connection === "disconnected";
    if (!wasDown && (this.unsubscribe || this.changesUnsupported || this.subscribingChanges || this.starting)) return;
    if (wasDown) {
      this.linkEpoch += 1;
      // The owner may have been replaced (an upgraded daemon): ask for the change stream again
      // even when the old one did not have it.
      this.changesUnsupported = false;
      // The old stream ended with the link; ask for a fresh one. The lost link's error would show
      // again as a banner while the re-read is on its way.
      this.unsubscribe?.();
      this.unsubscribe = undefined;
      this.set({ connection: "connecting", error: undefined });
    }
    this.refollow(alive);
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
      // cmux.protocol/2 sends a decimal as a string ("1791916418192"); `new Date("…")` of that is
      // an invalid date, and the grouping threw while rendering (a blank page, cx-hnmbt.8).
      const entries = result.entries.map((entry) => ({ ...entry, at_ms: Number(entry.at_ms) }));
      const pending = (result.pending_kinds?.length ?? 0) > 0;
      this.set({
        entries,
        groups: groupEntries(entries, this.snapshot.grouping),
        selection: reconcileSelection(entries, this.snapshot.selection),
        loading: false,
        pending,
        connection: "connected",
        error: undefined,
      });
      this.followPending(pending);
    } catch (error) {
      if (generation !== this.generation) return;
      this.set({ loading: false, ...failure(error) });
      // A failed re-read leaves the list not complete: the next wait still comes, unless the owner is gone.
      if (this.snapshot.connection === "disconnected") {
        this.clearPending();
        if (this.snapshot.pending) this.set({ pending: false });
      } else {
        this.followPending(this.snapshot.pending);
      }
    }
  }

  /** Runs the row's restore action in the app (page open, go to, reopen, resume, run again). */
  open(entry: HistoryEntry, newTab = false): Promise<void> {
    return this.intent(ACTION_RUN, { action: "history.open", args: { id: entry.id, newTab } }, false);
  }

  remove(entry: HistoryEntry): Promise<void> {
    return this.intent(HistoryOps.remove, { ids: [entry.id], idempotency_key: this.key() });
  }

  removeSite(entry: HistoryEntry): Promise<void> {
    const host = siteHost(entry);
    if (!host) return Promise.resolve();
    // Every profile's visits to the host go, as the native page's Remove All from This Site did.
    return this.intent(HistoryOps.removeSite, { host, idempotency_key: this.key() });
  }

  /** Clears the range of the kinds the filter shows (every kind under All). */
  clear(range: HistoryRange): Promise<void> {
    const kinds = filterKinds(this.snapshot.filter);
    return this.intent(HistoryOps.clear, {
      range,
      ...(kinds.length ? { kinds } : {}),
      idempotency_key: this.key(),
    });
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
    const lifetime = this.lifetime;
    try {
      await this.client.call(op, params);
      if (lifetime !== this.lifetime) return;
      if (this.snapshot.error) this.set({ error: undefined });
    } catch (error) {
      if (lifetime !== this.lifetime) return;
      this.set(failure(error));
      return;
    }
    // The provider also emits `cmux.history.changed`; re-reading here keeps the page correct when
    // the event is late, and the generation check drops the duplicate reply.
    if (lifetime === this.lifetime && reread) await this.reload();
  }

  private key(): string {
    return this.options.newKey?.() ?? crypto.randomUUID();
  }

  private set(patch: Partial<HistorySnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

/** The waits before each re-read of a list that is not complete; the last repeats. */
const PENDING_WAITS_MS = [1000, 2000, 4000, 8000];

function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function failure(error: unknown): Partial<HistorySnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) {
    return { connection: "disconnected", error: error.message };
  }
  return { error: message(error) };
}
