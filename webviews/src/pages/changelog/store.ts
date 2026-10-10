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
  /** An update's span (route `#/?from=<v>&to=<v>`): releases after `from` up to `to`. */
  span?: UpdateSpan;
  /** The listed builds inside the span. */
  inSpan: string[];
}

export interface UpdateSpan {
  from?: string;
  to: string;
}

/** `#/?from=1.2.0&to=1.3.0` (the host's ChangelogPageTab.route); undefined without `to`. */
export function parseSpan(hash: string): UpdateSpan | undefined {
  const query = hash.replace(/^#\/?/, "").replace(/^\?/, "");
  const params = new URLSearchParams(query);
  const to = params.get("to")?.trim();
  if (!to) return undefined;
  const from = params.get("from")?.trim();
  return from ? { from, to } : { to };
}

/** Orders release versions (`1.2.3`, `1.0.0-nightly.42`): numbers first, a prerelease before its release. */
export function compareVersions(a: string, b: string): number {
  const split = (v: string) => {
    const [core = "", pre] = v.split("-", 2);
    return { core: core.split(".").map((n) => Number(n) || 0), pre };
  };
  const x = split(a);
  const y = split(b);
  for (let i = 0; i < Math.max(x.core.length, y.core.length); i++) {
    const d = (x.core[i] ?? 0) - (y.core[i] ?? 0);
    if (d) return d;
  }
  if (x.pre === y.pre) return 0;
  if (x.pre === undefined) return 1;
  if (y.pre === undefined) return -1;
  const px = x.pre.split(".");
  const py = y.pre.split(".");
  for (let i = 0; i < Math.max(px.length, py.length); i++) {
    const [s, t] = [px[i], py[i]];
    if (s === t) continue;
    if (s === undefined) return -1;
    if (t === undefined) return 1;
    const [n, m] = [Number(s), Number(t)];
    if (Number.isFinite(n) && Number.isFinite(m)) return n - m;
    return s < t ? -1 : 1;
  }
  return 0;
}

function within(version: string, span: UpdateSpan): boolean {
  return (!span.from || compareVersions(version, span.from) > 0) && compareVersions(version, span.to) <= 0;
}

export class ChangelogStore {
  private snapshot: ChangelogSnapshot;
  private readonly listeners = new Set<() => void>();
  private readonly cache = new Map<string, ReleaseNotes>();
  private generation = 0;

  constructor(private readonly client: PageClient | null) {
    this.snapshot = { builds: [], loading: client !== null, missing: false, inSpan: [] };
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

  /** Loads the list, then the span's newest notes, else the running build's (or the newest listed). */
  async start(span?: UpdateSpan): Promise<void> {
    if (!this.client) return;
    try {
      const list = await this.client.call<ListResult>(ChangelogOps.list, {});
      const builds = list.builds.length ? list.builds : [];
      this.set({ builds, current: list.current, loading: false });
      if (span) return this.setSpan(span);
      await this.select(list.current || builds[0]?.build);
    } catch (error) {
      this.set({ loading: false, failed: isPageError(error) ? error.message : String(error) });
    }
  }

  /** Shows an update's span: its builds marked, the newest one selected. */
  async setSpan(span: UpdateSpan | undefined): Promise<void> {
    const inSpan = span ? this.snapshot.builds.filter((b) => within(b.shortVersion, span)) : [];
    const newest = [...inSpan].sort((a, b) => compareVersions(b.shortVersion, a.shortVersion))[0];
    this.set({ span, inSpan: inSpan.map((b) => b.build) });
    await this.select(newest?.build ?? (this.snapshot.current || this.snapshot.builds[0]?.build));
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
