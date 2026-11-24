// A page whose main thread stays busy, named while it happens, in every build (Leo, 2026-11-09,
// ask-a8e62e5885: "Currently, even after updating to restart, this is still showing up."). An agent
// pane's Chromium renderer ran at 115% CPU for 50 minutes in a nightly, and nothing said which page or
// which code: the debug probes (idleProbe.ts, `debug.agent_pane`) are not in a release build, the
// flicker log (flickerLog.ts) records frames, not the scripts that took them, and the dev perf budgets
// (devkit/perfBudgets.ts) run only under the dev server. createPageClient (pageClient.ts) installs it
// in every app page on the shared page host, the agent pane included.
//
// This reads Chromium's `long-animation-frame` entries, which name the scripts each long frame ran
// (invoker, function, file, character position), into 10 s windows. Once at least half of each of
// 3 windows in a row (30 s) went to long frames, it writes one `console.error` line starting
// `[cmux page busy]`: the busy and layout share, whether the page was shown, its element count and
// the scripts that took the time. The app's console capture (ConsoleErrorCapture) puts that line in
// the unified log and the error journal (`cmux errors --source page`) for every app page, Chromium
// included. While the page stays busy it repeats at most every 5 minutes.
//
// It runs no timer: it does work only when a long frame is reported, so a still page pays nothing.
// An engine without `long-animation-frame` (WebKit) installs nothing. Frames under 50 ms are not
// entries, so a loop made only of short tasks is not seen here.

export type LongFrameScript = {
  invoker?: string;
  invokerType?: string;
  sourceURL?: string;
  sourceFunctionName?: string;
  sourceCharPosition?: number;
  duration: number;
};

export type LongFrameEntry = {
  startTime: number;
  duration: number;
  /** When style and layout began in this frame (ms, same clock as startTime), where known. */
  styleAndLayoutStart?: number;
  scripts?: readonly LongFrameScript[];
};

export const BUSY_PREFIX = "[cmux page busy]";
/** One window's length (ms). */
export const BUSY_WINDOW_MS = 10_000;
/** The share of a window in long frames that counts it busy. */
export const BUSY_SHARE = 0.5;
/** Busy windows in a row before the first report. */
export const BUSY_WINDOWS = 3;
/** The least time between two reports while the page stays busy (ms). */
export const BUSY_REPEAT_MS = 5 * 60_000;
/** Scripts named in one report. */
const TOP_SCRIPTS = 4;
/** Distinct script places one busy run keeps: a run that lasts hours stays this size. */
const MAX_SITES = 200;

/// Adds `ms` to `site`, unless `sites` is full and does not have it.
function addSite(sites: Map<string, number>, site: string, ms: number): void {
  const held = sites.get(site);
  if (held === undefined && sites.size >= MAX_SITES) return;
  sites.set(site, (held ?? 0) + ms);
}

/// One script's place: what called it, then its function, file and character position.
export function scriptSite(script: LongFrameScript): string {
  const file = (script.sourceURL ?? "").split(/[?#]/)[0]!.split("/").pop() || "?";
  const name = script.sourceFunctionName || "(anonymous)";
  const at =
    typeof script.sourceCharPosition === "number" && script.sourceCharPosition >= 0
      ? `:${script.sourceCharPosition}`
      : "";
  const invoker = (script.invoker || script.invokerType || "?").slice(0, 80);
  return `${invoker} > ${name.slice(0, 80)}@${file.slice(0, 60)}${at}`;
}

type Bucket = { busy: number; layout: number; sites: Map<string, number> };

const emptyBucket = (): Bucket => ({ busy: 0, layout: 0, sites: new Map() });

const seconds = (ms: number) => `${(ms / 1000).toFixed(1)} s`;

export class BusyWatchdog {
  private origin: number | undefined;
  private index = 0;
  private open = emptyBucket();
  /** The busy windows in a row so far, summed. */
  private streak = 0;
  private run = emptyBucket();
  private lastReport = Number.NEGATIVE_INFINITY;

  constructor(
    private readonly report: (message: string) => void,
    private readonly describe: () => string = () => "",
  ) {}

  add(entries: readonly LongFrameEntry[]): void {
    for (const entry of entries) this.addOne(entry);
  }

  private addOne(entry: LongFrameEntry): void {
    if (!(entry.duration > 0) || !Number.isFinite(entry.startTime)) return;
    this.origin ??= entry.startTime;
    const index = Math.floor((entry.startTime - this.origin) / BUSY_WINDOW_MS);
    if (index > this.index) {
      this.close(this.open, entry.startTime);
      // A whole window with no long frame between them was not busy.
      if (index > this.index + 1) this.resetStreak();
      this.index = index;
      this.open = emptyBucket();
    }
    const bucket = this.open;
    bucket.busy += entry.duration;
    if (typeof entry.styleAndLayoutStart === "number" && entry.styleAndLayoutStart > 0)
      bucket.layout += Math.max(0, entry.startTime + entry.duration - entry.styleAndLayoutStart);
    for (const script of entry.scripts ?? []) {
      if (!(script.duration > 0)) continue;
      addSite(bucket.sites, scriptSite(script), script.duration);
    }
  }

  /// Ends a window, at the first long frame after it: a window counts only once it is over.
  private close(bucket: Bucket, at: number): void {
    if (bucket.busy < BUSY_SHARE * BUSY_WINDOW_MS) return this.resetStreak();
    this.streak += 1;
    merge(this.run, bucket);
    if (this.streak >= BUSY_WINDOWS) this.maybeReport(at, this.streak, this.run);
  }

  private resetStreak(): void {
    this.streak = 0;
    this.run = emptyBucket();
  }

  private maybeReport(at: number, windows: number, total: Bucket): void {
    if (at - this.lastReport < BUSY_REPEAT_MS) return;
    this.lastReport = at;
    const span = windows * BUSY_WINDOW_MS;
    const share = Math.min(100, Math.round((total.busy / span) * 100));
    const layout = total.busy > 0 ? Math.round((total.layout / total.busy) * 100) : 0;
    const top = [...total.sites.entries()]
      .sort((a, b) => b[1] - a[1])
      .slice(0, TOP_SCRIPTS)
      .map(([site, ms]) => `${site} ${seconds(ms)}`);
    const about = this.describe();
    const message =
      `${BUSY_PREFIX} main thread ${share}% busy in long frames for ${Math.round(span / 1000)} s ` +
      `(${seconds(total.busy)}, ${layout}% style and layout)` +
      (about ? `; ${about}` : "") +
      `; top scripts: ${top.length ? top.join(", ") : "none named"}`;
    this.report(message);
  }
}

function merge(into: Bucket, from: Bucket): void {
  into.busy += from.busy;
  into.layout += from.layout;
  for (const [site, ms] of from.sites) addSite(into.sites, site, ms);
}

/// What a report says about the page itself: no text of it, only its state and size.
export function describePage(doc: Document): string {
  return `page ${doc.visibilityState}, ${doc.getElementsByTagName("*").length} elements`;
}

let installed = false;

/// Starts the watchdog once per document. False when the engine has no long-animation-frame
/// entries or refuses the observer; a watchdog that cannot start never stops the page.
export function installBusyWatchdog(win: Window & typeof globalThis = window): boolean {
  if (installed) return true;
  try {
    const Observer = win.PerformanceObserver;
    if (!Observer?.supportedEntryTypes?.includes("long-animation-frame")) return false;
    const doc = win.document;
    const dog = new BusyWatchdog(
      (message) => win.console.error(message),
      () => describePage(doc),
    );
    new Observer((list) => dog.add(list.getEntries() as unknown as LongFrameEntry[])).observe({
      type: "long-animation-frame",
      buffered: true,
    });
    installed = true;
    return true;
  } catch {
    return false;
  }
}
