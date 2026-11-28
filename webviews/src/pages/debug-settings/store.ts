// The Debug Settings page's state on the page side: the last state the app sent and the intents
// the page sends. The app (DebugSettingsModel) owns search, selection, values and the notice; the
// page keeps no optimistic copy except the text being typed in the search field. React reads it
// through `useSyncExternalStore` (no effects).
import { isPageError, type PageClient } from "../shared/pageClient";
import { LINK_CLOSED, subscribePageStreams } from "../shared/pageStreams";
import { CLIPBOARD_WRITE, DebugTunablesOps, type DebugSettingsState, type TunableValue } from "./types";

export type Connection = "connecting" | "connected" | "disconnected";

export interface DebugSettingsSnapshot {
  state?: DebugSettingsState;
  /** The search field's text: what the person typed until the app answers for it, else the app's. */
  query: string;
  connection: Connection;
  /** The last failed intent's message, cleared by the next success. */
  error?: string;
}

export interface DebugSettingsStoreOptions {
  /** The pasteboard write the page can do itself; falls back to the host op when it rejects. */
  writeClipboard?: (text: string) => Promise<void>;
}

export class DebugSettingsStore {
  private snapshot: DebugSettingsSnapshot;
  private readonly listeners = new Set<() => void>();
  private unsubscribe?: () => void;
  private unpage?: () => void;
  private starting = false;
  private generation = 0;
  /** A typed search the app has not answered yet. */
  private pendingQuery?: string;

  constructor(
    private readonly client: PageClient | null,
    private readonly options: DebugSettingsStoreOptions = {},
  ) {
    this.snapshot = { query: "", connection: client ? "connecting" : "disconnected" };
  }

  getSnapshot = (): DebugSettingsSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    if (this.listeners.size === 1) void this.start();
    return () => {
      this.listeners.delete(listener);
      if (this.listeners.size === 0) this.stop();
    };
  };

  /** Subscribes to changes, then reads the first state. Idempotent. */
  async start(): Promise<void> {
    if (!this.client || this.unsubscribe || this.starting) return;
    this.starting = true;
    try {
      const unsubscribe = await this.client.subscribe<{ state?: DebugSettingsState }>(
        DebugTunablesOps.changed,
        (data) => {
          if (data?.state) this.accept(data.state);
        },
      );
      // The page went away while the subscribe was in flight.
      if (this.listeners.size === 0) return unsubscribe();
      this.unsubscribe = unsubscribe;
      const unpage = await subscribePageStreams(this.client, {
        onConnection: (connected) => {
          if (!connected) this.set({ connection: "disconnected" });
          else if (this.snapshot.connection === "disconnected") {
            // A start that failed while the host was gone tries again.
            if (!this.unsubscribe) void this.start();
            else void this.reload();
          }
        },
      });
      if (this.listeners.size === 0) {
        unpage();
        return this.stop();
      }
      this.unpage = unpage;
    } catch (error) {
      this.set(failure(error));
      return;
    } finally {
      this.starting = false;
    }
    await this.reload();
  }

  stop(): void {
    this.unsubscribe?.();
    this.unsubscribe = undefined;
    this.unpage?.();
    this.unpage = undefined;
  }

  async reload(): Promise<void> {
    await this.intent(DebugTunablesOps.state, {});
  }

  setQuery(query: string): Promise<void> {
    // Show the typed text at once; the app's reply carries the filtered rows.
    this.pendingQuery = query;
    this.set({ query });
    return this.intent(DebugTunablesOps.viewSet, { query });
  }

  /** A sidebar choice; the app clears the search. */
  select(selection: string): Promise<void> {
    this.pendingQuery = undefined;
    return this.intent(DebugTunablesOps.viewSet, { selection });
  }

  setValue(key: string, value: TunableValue | null): Promise<void> {
    return this.intent(DebugTunablesOps.set, { key, value });
  }

  reset(target: { key: string } | { section: string } | { all: true }): Promise<void> {
    return this.intent(DebugTunablesOps.reset, target);
  }

  /** Copies the changed values (`json`) or Swift defaults (`swift`); the app sets the notice. */
  async copy(format: "json" | "swift"): Promise<void> {
    if (!this.client) return;
    let text: string;
    try {
      ({ text } = await this.client.call<{ text: string }>(DebugTunablesOps.export, { format }));
    } catch (error) {
      this.set(failure(error));
      return;
    }
    try {
      if (!this.options.writeClipboard) throw new Error("no page clipboard");
      await this.options.writeClipboard(text);
    } catch {
      try {
        await this.client.call(CLIPBOARD_WRITE, { text });
      } catch (error) {
        this.set(failure(error));
      }
    }
  }

  /** Every op answers the new state; an older reply that arrives late is dropped. */
  private async intent(op: string, params: unknown): Promise<void> {
    if (!this.client) return;
    const generation = ++this.generation;
    try {
      const state = await this.client.call<DebugSettingsState>(op, params);
      if (generation !== this.generation) return;
      this.accept(state);
    } catch (error) {
      // A refused search must not hold the field: the app's query shows again.
      if (op === DebugTunablesOps.viewSet) this.pendingQuery = undefined;
      if (generation === this.generation) this.set(failure(error));
    }
  }

  private accept(state: DebugSettingsState): void {
    // While the person types, a change event for an older query must not move the field back.
    if (this.pendingQuery === state.query) this.pendingQuery = undefined;
    this.set({ state, query: this.pendingQuery ?? state.query, connection: "connected", error: undefined });
  }

  private set(patch: Partial<DebugSettingsSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }
}

function failure(error: unknown): Partial<DebugSettingsSnapshot> {
  if (isPageError(error) && error.code === LINK_CLOSED) return { connection: "disconnected", error: error.message };
  return { error: error instanceof Error ? error.message : String(error) };
}
