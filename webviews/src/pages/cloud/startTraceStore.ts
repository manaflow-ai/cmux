// Cloud start timings' state (DEV and NIGHTLY): the last day's starts and the one shown as a waterfall.
// It reads on demand only (the page's first read, opening the view, Refresh, picking a start): no
// timer, no polling. A build that does not serve the ops answers unsupported once and `available`
// stays false, so the page shows no entry for them (the Cloud app server serves them only in DEV and
// NIGHTLY builds). React reads it through `useSyncExternalStore`; a reply older than a newer read is
// dropped.
import type { PageClient } from "../shared/pageClient";
import { CloudOps, isUnsupported, type AuthStatus } from "./ops";
import type { CloudStore } from "./store";
import { isTraceId, type StartTrace, type StartTraceList } from "./startTraces";

export interface StartTraceSnapshot {
  /** null until the first read answers; false when this build does not serve start traces. */
  available: boolean | null;
  list?: StartTraceList;
  /** The start the waterfall shows (the newest by default). */
  selected?: string;
  trace?: StartTrace;
  loading: boolean;
  error?: string;
}

/** The newest starts the view lists. */
export const START_TRACE_LIMIT = 50;

export class StartTraceStore {
  private snapshot: StartTraceSnapshot = { available: null, loading: false };
  private readonly listeners = new Set<() => void>();
  private listRead = 0;
  private traceRead = 0;

  constructor(private readonly client: PageClient | null) {}

  getSnapshot = (): StartTraceSnapshot => this.snapshot;

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };

  private set(patch: Partial<StartTraceSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...patch };
    for (const listener of this.listeners) listener();
  }

  /** Forgets everything read (a sign-out, another account or team): the traces are the old team's.
   * Reads in flight are dropped when they answer. */
  reset(): void {
    this.listRead++;
    this.traceRead++;
    this.set({
      available: null,
      list: undefined,
      selected: undefined,
      trace: undefined,
      loading: false,
      error: undefined,
    });
  }

  /** Reads the last day's starts, then the selected one (or the newest). */
  async refresh(): Promise<void> {
    if (!this.client) return this.set({ available: false });
    const read = ++this.listRead;
    this.set({ loading: true });
    try {
      const list = await this.client.call<StartTraceList>(CloudOps.startTraceList, { limit: START_TRACE_LIMIT });
      if (read !== this.listRead) return;
      const traces = Array.isArray(list?.traces) ? list.traces : [];
      const keep = traces.some((one) => one.trace === this.snapshot.selected) ? this.snapshot.selected : undefined;
      const selected = keep ?? traces[0]?.trace;
      this.set({
        available: true,
        list: { ...list, traces, hops: list?.hops ?? {} },
        loading: false,
        error: undefined,
      });
      if (selected) await this.select(selected);
      else {
        // A start read still in flight belongs to a list that is gone: its answer is dropped.
        this.traceRead++;
        this.set({ selected: undefined, trace: undefined });
      }
    } catch (error) {
      if (read !== this.listRead) return;
      if (isUnsupported(error)) return this.set({ available: false, loading: false });
      this.set({ loading: false, error: message(error) });
    }
  }

  /** Shows one start as the waterfall. */
  async select(trace: string): Promise<void> {
    if (!this.client || !isTraceId(trace)) return;
    const read = ++this.traceRead;
    this.set({ selected: trace, trace: this.snapshot.trace?.trace === trace ? this.snapshot.trace : undefined });
    try {
      const answer = await this.client.call<StartTrace>(CloudOps.startTraceGet, { trace });
      if (read !== this.traceRead) return;
      const spans = Array.isArray(answer?.spans) ? answer.spans : [];
      this.set({ trace: { ...answer, spans }, error: undefined });
    } catch (error) {
      if (read !== this.traceRead) return;
      this.set({ trace: undefined, error: message(error) });
    }
  }
}

/** The timings follow the page's account: each auth answer the Cloud store takes (a sign-in, a
 * sign-out, another user or team, a restored session) forgets what was read for the previous one
 * and, when signed in, reads again. Returns the unsubscribe. */
export function followAccount(cloud: CloudStore, timings: StartTraceStore): () => void {
  let seen: AuthStatus | undefined;
  const sync = () => {
    const auth = cloud.getSnapshot().auth;
    if (auth === seen) return;
    seen = auth;
    timings.reset();
    if (auth?.signedIn) void timings.refresh();
  };
  const unsubscribe = cloud.subscribe(sync);
  sync();
  return unsubscribe;
}

function message(error: unknown): string {
  return error instanceof Error && error.message ? error.message : String(error);
}
