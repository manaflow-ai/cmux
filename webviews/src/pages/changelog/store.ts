// The changelog page's state owner: the build list, the selected build and its notes. Notes are a
// projection of the provider; the page keeps no copy beyond a per-build cache. React reads it
// through `useSyncExternalStore` (no effects).
import { isPageError, type PageClient } from "../shared/pageClient";
import {
  ACTION_RUN,
  ChangelogOps,
  type ChangelogDesign,
  type IndexEntry,
  type ListResult,
  type NewsLayout,
  type ReelResult,
  type ReleaseNotes,
} from "./types";

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
  /** Every build's notes loaded so far (the journal shows several releases at once). */
  loaded: Record<string, ReleaseNotes>;
  /** Builds whose notes could not be loaded (offline, unsigned). */
  unavailable: Record<string, true>;
  /** The span's nightly reels by build (https links only), asked after the notes: the first
      screen never waits for them. */
  reels: Record<string, string>;
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

/** The design the route names (`design=journal|rail|digest`, Debug Settings `whatsNew.design`); journal by default. */
export function parseDesign(hash: string): ChangelogDesign {
  const query = hash.replace(/^#\/?/, "").replace(/^\?/, "");
  const design = new URLSearchParams(query).get("design");
  return design === "journal" || design === "rail" || design === "digest" ? design : "ledger";
}

/** The update's news layout the route names (`news=alternate|stack|lead`); grid by default. */
export function parseNewsLayout(hash: string): NewsLayout {
  const query = hash.replace(/^#\/?/, "").replace(/^\?/, "");
  const news = new URLSearchParams(query).get("news");
  return news === "alternate" || news === "stack" || news === "lead" ? news : "grid";
}

/** Orders release versions (`1.2.3`, `1.0.0-nightly.42`): numbers first, a prerelease before its release. */
export function compareVersions(a: string, b: string): number {
  const split = (v: string) => {
    const dash = v.indexOf("-");
    const core = dash < 0 ? v : v.slice(0, dash);
    const pre = dash < 0 ? undefined : v.slice(dash + 1);
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
  private readonly pending = new Map<string, Promise<ReleaseNotes | undefined>>();
  private generation = 0;
  private readonly askedReels = new Set<string>();
  private listed = false;
  /** The latest span the route named; applied once the list has loaded. */
  private latestSpan?: UpdateSpan;
  /** ``start``'s load (the list, then the span's or the selected build's notes). */
  private started: Promise<void> = Promise.resolve();

  constructor(private readonly client: PageClient | null) {
    this.snapshot = {
      builds: [],
      loading: client !== null,
      missing: false,
      inSpan: [],
      loaded: {},
      unavailable: {},
      reels: {},
    };
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
  start(span?: UpdateSpan): Promise<void> {
    this.started = this.load(span);
    return this.started;
  }

  /** Settles once the first screen's data has: the list, the selected build's notes and the notes
      of every section in view (the journal asks for them as it renders), loaded or unavailable. */
  async firstScreen(): Promise<void> {
    await this.started;
    // Each load renders the page again, and a section that moved into view asks for its builds then.
    for (;;) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      if (this.pending.size === 0) return;
      await Promise.allSettled(this.pending.values());
    }
  }

  private async load(span?: UpdateSpan): Promise<void> {
    if (!this.client) return;
    this.latestSpan = span;
    try {
      const list = await this.client.call<ListResult>(ChangelogOps.list, {});
      const builds = list.builds.length ? list.builds : [];
      this.listed = true;
      this.set({ builds, current: list.current, loading: false });
      // A route change while the list loaded wins over the first route.
      if (this.latestSpan) return this.setSpan(this.latestSpan);
      await this.select(list.current || builds[0]?.build);
    } catch (error) {
      this.set({ loading: false, failed: isPageError(error) ? error.message : String(error) });
    }
  }

  /** Shows an update's span: its builds marked, the newest one selected. */
  async setSpan(span: UpdateSpan | undefined): Promise<void> {
    this.latestSpan = span;
    if (!this.listed) return;
    const inSpan = span ? this.snapshot.builds.filter((b) => within(b.shortVersion, span)) : [];
    const newest = [...inSpan].sort((a, b) => compareVersions(b.shortVersion, a.shortVersion))[0];
    this.set({ span, inSpan: inSpan.map((b) => b.build) });
    // The update's section reads every build of the span at once (the index keeps at most 50).
    for (const b of inSpan) void this.ensure(b.build);
    for (const b of inSpan) void this.ensureReel(b.build);
    await this.select(newest?.build ?? (this.snapshot.current || this.snapshot.builds[0]?.build));
  }

  async select(build: string | undefined): Promise<void> {
    if (!build || !this.client) return;
    const generation = ++this.generation;
    const cached = this.cache.get(build);
    this.set({ selected: build, notes: cached, missing: false });
    if (cached) return;
    const notes = await this.ensure(build);
    if (generation === this.generation)
      this.set(notes ? { notes, missing: false } : { notes: undefined, missing: true });
  }

  /** Loads one build's notes once (the journal asks as a release scrolls near); undefined when unavailable. */
  async ensure(build: string): Promise<ReleaseNotes | undefined> {
    const cached = this.cache.get(build);
    // An unavailable build is not asked again on every render (the page re-renders on each load).
    if (cached || !this.client || this.snapshot.unavailable[build]) return cached;
    const pending = this.pending.get(build);
    if (pending) return pending;
    const load = this.client
      .call<ReleaseNotes>(ChangelogOps.get, { build })
      .then((notes) => {
        this.cache.set(build, notes);
        this.set({ loaded: { ...this.snapshot.loaded, [build]: notes } });
        return notes;
      })
      .catch(() => {
        this.set({ unavailable: { ...this.snapshot.unavailable, [build]: true } });
        return undefined;
      })
      .finally(() => this.pending.delete(build));
    this.pending.set(build, load);
    return load;
  }

  /** Asks for one build's reel once; an older host without the op, or no reel, shows no card. */
  private async ensureReel(build: string): Promise<void> {
    if (!this.client || build in this.snapshot.reels || this.askedReels.has(build)) return;
    this.askedReels.add(build);
    try {
      const { url } = await this.client.call<ReelResult>(ChangelogOps.reel, { build });
      if (url?.startsWith("https://")) this.set({ reels: { ...this.snapshot.reels, [build]: url } });
    } catch {
      // No reel: the page shows what it has.
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
