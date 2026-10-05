// The changelog page's state owner: the build list, the selected build and its notes. Notes are a
// projection of the provider; the page keeps no copy beyond a per-build cache. React reads it
// through `useSyncExternalStore` (no effects).
import { isPageError, type PageClient } from "../shared/pageClient";
import { ACTION_RUN, ChangelogOps, type IndexEntry, type ListResult, type ReleaseNotes } from "./types";

export interface ChangelogSnapshot {
  builds: IndexEntry[];
  current?: string;
  selected?: string;
  notes?: ReleaseNotes;
  loading: boolean;
  /** The selected build has no verified notes (offline before the first fetch, or unsigned). */
  missing: boolean;
  failed?: string;
}

export class ChangelogStore {
  private snapshot: ChangelogSnapshot;
  private readonly listeners = new Set<() => void>();
  private readonly cache = new Map<string, ReleaseNotes>();
  private generation = 0;

  constructor(private readonly client: PageClient | null) {
    this.snapshot = { builds: [], loading: client !== null, missing: false };
  }

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };

  getSnapshot = (): ChangelogSnapshot => this.snapshot;

  private set(next: Partial<ChangelogSnapshot>): void {
    this.snapshot = { ...this.snapshot, ...next };
    for (const listener of this.listeners) listener();
  }

  /** Loads the list, then the running build's notes (or the newest listed). */
  async start(): Promise<void> {
    if (!this.client) return;
    try {
      const list = await this.client.call<ListResult>(ChangelogOps.list, {});
      const builds = list.builds.length ? list.builds : [];
      this.set({ builds, current: list.current, loading: false });
      await this.select(list.current || builds[0]?.build);
    } catch (error) {
      this.set({ loading: false, failed: isPageError(error) ? error.message : String(error) });
    }
  }

  async select(build: string | undefined): Promise<void> {
    if (!build || !this.client) return;
    const generation = ++this.generation;
    const cached = this.cache.get(build);
    this.set({ selected: build, notes: cached, missing: false });
    if (cached) return;
    try {
      const notes = await this.client.call<ReleaseNotes>(ChangelogOps.get, { build });
      this.cache.set(build, notes);
      if (generation === this.generation) this.set({ notes, missing: false });
    } catch {
      if (generation === this.generation) this.set({ notes: undefined, missing: true });
    }
  }

  /** "Try it": the host runs the action only when it is on the allow-list. */
  async tryIt(action: string): Promise<void> {
    try {
      await this.client?.call(ACTION_RUN, { action });
    } catch (error) {
      this.set({ failed: isPageError(error) ? error.message : String(error) });
    }
  }
}
