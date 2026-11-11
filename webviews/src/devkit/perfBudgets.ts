// Runtime perf budgets for development: the classes of bug that most past web perf and flicker fixes
// were about, caught as a console warning while you edit under `cmux live` rather than after a
// merge (docs/cmux-next/hot-reload.md, "Runtime perf budgets"). Five classes, each with one fix:
//
// - `layout-shift`: something moved after it painted, with no input to explain it (#29744 a sent
//   prompt flickered, #24503 a slide ended with a jump, #30543 estimated heights replaced by real
//   ones). Chromium's `layout-shift` entries, `hadRecentInput === false`.
// - `dom-breadth`: one element with more than 300 element children, a list drawn whole instead of
//   its visible window (#36132, a picker with thousands of projects). Checked after DOM changes,
//   over the added subtrees only, in idle batches.
// - `live-intervals`: more than 20 live `setInterval` handles, a timer per item instead of the
//   page's clock (#28753). `setInterval`, `clearInterval` and `clearTimeout` are wrapped to count.
// - `long-frame`: a frame over 50 ms (`long-animation-frame`, where the engine has it).
// - `react-commit`: a root that commits more than 120 times in a second (more than one per frame
//   even at 120 Hz, so commits nobody sees) or spends more than 16 ms rendering one commit, a stream that redraws
//   every row instead of its own (#34004, #27911). Read from React's devtools hook, every root.
// - `still-surface`: a surface that holds still while the page around it changes (marked
//   `data-perf-still`: the agent pane's composer and the hat over it) had its nodes or attributes
//   rewritten in more than 6 of the last 10 seconds with no key or pointer input: a clock tick, a tool
//   step or another chat's status drew it again (Leo, 2026-11-09: "im still sometimes seeing a flicker on the
//   composer/composer hat when scrolling and things are running in background aka time is ticking").
//   The rate and commit budgets above never saw it: a redraw a second, or four, is far under 120
//   commits and 16 ms, and nothing moved. A text node that ticks in place (a running time in its own
//   leaf) is not counted.
//
// Each warning is one `console.warn` starting with `[cmux perf budget]`, naming the class, the
// measured value against the budget, where (a node, a call site, a script, a root) and the fix.
// A warning fires once per class and site. A page's own load and the second after a hot update
// are not budgeted for long frames, commit time and layout shift: both rebuild the page at once.
//
// An element opts out with `data-perf-budget-allow="<reason>"` (its children are not counted; a
// shift of it is not reported). `stop()` disconnects every observer, puts the timers back and
// detaches from the hook; `pagehide` stops it too. Nothing here runs in a production bundle: the
// dev server injects perfBudgets.dev.ts into the pages it serves (dev-server/plugins.ts).

export type PerfBudgetMode = "warn" | "collect" | "throw" | "off";
export type PerfBudgetClass =
  | "layout-shift"
  | "dom-breadth"
  | "live-intervals"
  | "long-frame"
  | "react-commit"
  | "still-surface";

export type PerfBudgetViolation = {
  kind: PerfBudgetClass;
  /** What the budget names: a node, a call site, a script or a React root. */
  site: string;
  measured: number;
  budget: number;
  unit: string;
  fix: string;
  message: string;
};

export const PERF_BUDGETS = {
  /** A node moved this far (px) with no input: a jump anyone notices. Smaller is sub-pixel noise. */
  layoutShiftPx: 8,
  /** Layout-shift score summed over a 1 s window: many small moves of a large area. */
  layoutShiftScore: 0.01,
  /** Element children of one element: a few screens of rows; VirtualList keeps ~40. */
  domChildren: 300,
  /** Live intervals on a page: the page clock needs one per cadence, not one per item. */
  liveIntervals: 20,
  /** One frame (ms): RAIL's response budget; three dropped frames at 60 Hz. */
  longFrameMs: 50,
  /** Commits of one root in a second: more than one per frame even on a 120 Hz display paints nothing new. */
  commitsPerSecond: 120,
  /** Render time of one commit (ms): half a frame in development React, about 8 ms in production. */
  commitMs: 16,
  /** Seconds of the last ten in which a `data-perf-still` surface's nodes or attributes were rewritten
   *  with no input. Its own events come in bursts (a chat opening draws the composer four times in
   *  its first second, a turn starting and ending a second each); a redraw per clock second or per
   *  event elsewhere fills every second, each one rewriting its inputs' attributes (React sets an
   *  input's name and type on every update). */
  stillSeconds: 6,
};
export type PerfBudgetLimits = typeof PERF_BUDGETS;

export const PERF_BUDGET_PREFIX = "[cmux perf budget]";
export const PERF_BUDGET_ALLOW = "data-perf-budget-allow";
/** Marks a surface that holds still while the page around it changes (`still-surface`). */
export const PERF_BUDGET_STILL = "data-perf-still";

const FIX: Record<PerfBudgetClass, string> = {
  "layout-shift":
    "reserve the final size before first paint (measure, then show) or move it with a transform; a height change animates every affected element together",
  "dom-breadth":
    'render the visible window: VirtualList (src/ui/VirtualList.tsx) or Combobox virtualRows (src/ui/Combobox.tsx); or mark the element data-perf-budget-allow="<reason>"',
  "live-intervals":
    "subscribe to the page clock instead of a timer per item: subscribePageSecond, usePageNow or visibleInterval (src/ui/pageClock.ts; cmuxDebug.loops() in src/ui/pageLoops.ts lists them)",
  "long-frame":
    "do less per frame: render only the visible window (VirtualList), defer off-screen work, or split the work across frames",
  "react-commit":
    "re-render only what changed: give a streamed item its own subscription or a memoized row, and batch updates to one commit per frame",
  "still-surface":
    "draw the surface only on its own events: memoize it on what it shows (agent-session/acpmux/composer/composerView.ts), and put a ticking value in a leaf of its own (agent-session/acpmux/subagents/Elapsed.tsx)",
};

/** After a load or a hot update, how long the page is rebuilding and not budgeted (ms). */
const SETTLE_MS = 1000;
/** Most elements one breadth check walks; the rest wait for the next change. */
const BREADTH_WALK_LIMIT = 20_000;
/** Most added subtrees held between checks; past it the next check walks the body. */
const BREADTH_PENDING_LIMIT = 500;
const BREADTH_DELAY_MS = 250;
/** The seconds a still surface's redraws are counted over: its own bursts pass, a 1 Hz redraw does not. */
const STILL_WINDOW_S = 10;
const OWN_FILE = "perfBudgets";

export type PerfBudgetsOptions = {
  mode?: PerfBudgetMode;
  budgets?: Partial<PerfBudgetLimits>;
  /** Where warnings go in `warn` mode (console.warn). */
  report?: (message: string) => void;
  /** How long a load or hot update is not budgeted (ms); tests shorten it. */
  settleMs?: number;
};

export type PerfBudgetsHandle = {
  readonly mode: PerfBudgetMode;
  readonly violations: PerfBudgetViolation[];
  /** Runs the checks that wait (queued observer entries, the breadth batch) now: for tests. */
  flush(): void;
  /** The page is rebuilding (a hot update): no frame, commit or shift budget for a second. */
  settle(): void;
  stop(): void;
};

type ReactHook = {
  renderers?: Map<number, unknown>;
  supportsFiber?: boolean;
  inject?: (renderer: unknown) => number;
  onCommitFiberRoot?: (id: number, root: FiberRoot, ...rest: unknown[]) => unknown;
  onCommitFiberUnmount?: (...args: unknown[]) => unknown;
  onScheduleFiberRoot?: (...args: unknown[]) => unknown;
};
type FiberRoot = { current?: { actualDuration?: number }; containerInfo?: unknown };

type LoafScript = { invoker?: string; sourceURL?: string; sourceFunctionName?: string; duration: number };
type LoafEntry = PerformanceEntry & { scripts?: LoafScript[] };
type ShiftSource = { node?: Node | null; previousRect: DOMRectReadOnly; currentRect: DOMRectReadOnly };
type ShiftEntry = PerformanceEntry & { value: number; hadRecentInput: boolean; sources?: ShiftSource[] };

/** `tag#id.class.class` of a node, short enough for one console line. */
export function describeNode(node: Node | null | undefined): string {
  if (!node) return "?";
  const element = node.nodeType === 1 ? (node as Element) : node.parentElement;
  if (!element) return node.nodeName.toLowerCase();
  const id = element.id ? `#${element.id}` : "";
  const classes = [...element.classList].slice(0, 3).join(".");
  const page = element.ownerDocument?.documentElement.getAttribute("data-cmux-page");
  return `${element.tagName.toLowerCase()}${id}${classes ? `.${classes}` : ""}${page && !id && !classes ? ` (${page})` : ""}`;
}

/** The first frame of the caller's stack outside this file. */
function callSite(): string {
  const lines = (new Error().stack ?? "").split("\n").slice(1);
  // A frame of a script (path:line:column), not this file's and not the engine's own (Array.from).
  const line =
    lines.find((text) => !text.includes(OWN_FILE) && !text.includes("native") && /:\d+:\d+\)?\s*$/.test(text)) ??
    "unknown";
  return line
    .trim()
    .replace(/^at /, "")
    .replace(/\?[^:)]*(?=:\d)/, "")
    .slice(0, 200);
}

function allowed(node: Node | null | undefined): boolean {
  const element = node?.nodeType === 1 ? (node as Element) : node?.parentElement;
  return Boolean(element?.closest?.(`[${PERF_BUDGET_ALLOW}]`));
}

/**
 * Starts the budgets on `win`. In `off` mode, or on a window that is not a browser page, it does
 * nothing and returns a handle whose stop() does nothing.
 */
export function startPerfBudgets(win: Window = window, options: PerfBudgetsOptions = {}): PerfBudgetsHandle {
  const mode = options.mode ?? "warn";
  const violations: PerfBudgetViolation[] = [];
  if (mode === "off" || !win?.document) return { mode, violations, flush() {}, settle() {}, stop() {} };

  const budgets = { ...PERF_BUDGETS, ...options.budgets };
  const report = options.report ?? ((message: string) => console.warn(message));
  const doc = win.document;
  const now = () => win.performance.now();
  const settleMs = options.settleMs ?? SETTLE_MS;
  const reported = new Set<string>();
  const stops: (() => void)[] = [];
  /** Each check that waits (an observer's queue, the breadth batch), run now by flush(). */
  const flushes: (() => void)[] = [];
  let stopped = false;
  // The page's own load is not budgeted; nor is the second after a hot update.
  let quietUntil = doc.readyState === "complete" ? now() + settleMs : Number.POSITIVE_INFINITY;
  const settling = () => now() < quietUntil;

  const violate = (kind: PerfBudgetClass, site: string, measured: number, budget: number, unit: string) => {
    const key = `${kind} ${site}`;
    if (stopped || reported.has(key)) return;
    reported.add(key);
    const round = (value: number) => (Number.isInteger(value) ? value : Number(value.toFixed(value < 1 ? 3 : 1)));
    const message = `${PERF_BUDGET_PREFIX} ${kind}: ${round(measured)}${unit} over the budget of ${round(budget)}${unit} at ${site}. Fix: ${FIX[kind]}.`;
    const violation = { kind, site, measured, budget, unit, fix: FIX[kind], message };
    violations.push(violation);
    if (mode === "warn") report(message);
    else if (mode === "throw") throw new Error(message);
  };

  const setTimer = win.setTimeout.bind(win);
  const clearTimer = win.clearTimeout.bind(win);
  const onLoad = () => {
    quietUntil = now() + settleMs;
  };
  if (doc.readyState !== "complete") {
    win.addEventListener("load", onLoad, { once: true });
    stops.push(() => win.removeEventListener("load", onLoad));
  }

  // live-intervals: count handles by the call site that made them.
  {
    const ownSet = win.setInterval;
    const ownClear = win.clearInterval;
    const ownClearTimeout = win.clearTimeout;
    const live = new Map<number, string>();
    const perSite = new Map<string, number>();
    const forget = (id: unknown) => {
      const site = live.get(id as number);
      if (site === undefined) return;
      live.delete(id as number);
      const count = (perSite.get(site) ?? 1) - 1;
      if (count > 0) perSite.set(site, count);
      else perSite.delete(site);
    };
    const wrappedSet = function (this: unknown, handler: TimerHandler, timeout?: number, ...rest: unknown[]) {
      const id = Reflect.apply(ownSet, win, [handler, timeout, ...rest]) as number;
      const site = callSite();
      live.set(id, site);
      perSite.set(site, (perSite.get(site) ?? 0) + 1);
      if (live.size > budgets.liveIntervals) {
        // Name the site holding the most: the one that grows with items.
        let worst = site;
        for (const [name, count] of perSite) if (count > (perSite.get(worst) ?? 0)) worst = name;
        violate("live-intervals", worst, live.size, budgets.liveIntervals, " live intervals");
      }
      return id;
    } as typeof win.setInterval;
    const wrappedClear = function (id?: number) {
      forget(id);
      return Reflect.apply(ownClear, win, [id]);
    } as typeof win.clearInterval;
    // Intervals and timeouts share one list of handles: clearTimeout clears an interval too.
    const wrappedClearTimeout = function (id?: number) {
      forget(id);
      return Reflect.apply(ownClearTimeout, win, [id]);
    } as typeof win.clearTimeout;
    win.setInterval = wrappedSet;
    win.clearInterval = wrappedClear;
    win.clearTimeout = wrappedClearTimeout;
    stops.push(() => {
      // Put back only our own wrappers: a later wrapper (an idle probe) restores itself.
      if (win.setInterval === wrappedSet) win.setInterval = ownSet;
      if (win.clearInterval === wrappedClear) win.clearInterval = ownClear;
      if (win.clearTimeout === wrappedClearTimeout) win.clearTimeout = ownClearTimeout;
    });
  }

  // still-surface: one observer on every marked surface the breadth walk finds as it is added, counting
  // its node and attribute changes per second while no key or pointer input explains them.
  const stillSeen = new WeakSet<Element>();
  /** Each surface's seconds (page time / 1000, floored) with a redraw, the last ten at most. */
  const stillRedrawn = new WeakMap<Element, number[]>();
  let lastInput = Number.NEGATIVE_INFINITY;
  // One call is one batch of changes, one React commit: each surface it touched counts one redraw.
  const stillChanged = (records: MutationRecord[]) => {
    const at = now();
    if (at - lastInput < 1000 || settling() || doc.visibilityState !== "visible") return;
    const touched = new Set<Element>();
    for (const record of records) {
      // A text node that changes in place (a running time) is the leaf doing its job.
      if (record.type === "characterData") continue;
      const target = record.target.nodeType === 1 ? (record.target as Element) : record.target.parentElement;
      const surface = target?.closest(`[${PERF_BUDGET_STILL}]`);
      if (surface) touched.add(surface);
    }
    const second = Math.floor(at / 1000);
    for (const surface of touched) {
      const seconds = stillRedrawn.get(surface) ?? [];
      if (seconds.at(-1) !== second) seconds.push(second);
      while (seconds.length > 0 && seconds[0]! <= second - STILL_WINDOW_S) seconds.shift();
      stillRedrawn.set(surface, seconds);
      if (seconds.length > budgets.stillSeconds)
        violate("still-surface", describeNode(surface), seconds.length, budgets.stillSeconds, " of 10 s redrawn");
    }
  };
  const stillObserver = new (win as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver(
    stillChanged,
  );
  function watchStill(element: Element) {
    if (stillSeen.has(element)) return;
    stillSeen.add(element);
    stillObserver.observe(element, { subtree: true, childList: true, attributes: true, characterData: true });
  }
  {
    const input = () => {
      lastInput = now();
    };
    const kinds = ["keydown", "pointerdown", "pointermove", "compositionupdate", "input"] as const;
    for (const kind of kinds) doc.addEventListener(kind, input, { capture: true, passive: true });
    flushes.push(() => stillChanged(stillObserver.takeRecords()));
    stops.push(() => {
      stillObserver.disconnect();
      for (const kind of kinds) doc.removeEventListener(kind, input, { capture: true });
    });
  }

  // dom-breadth: added subtrees and grown parents, checked in one batch a quarter second after a change.
  {
    const pending = new Set<Element>();
    let overflow = false;
    let timer: number | undefined;
    const check = () => {
      timer = undefined;
      const roots = overflow || pending.size === 0 ? (doc.body ? [doc.body] : []) : [...pending];
      pending.clear();
      overflow = false;
      let budget = BREADTH_WALK_LIMIT;
      const stack: Element[] = roots.filter((root) => root.isConnected);
      while (stack.length > 0 && budget-- > 0) {
        const element = stack.pop()!;
        if (element.hasAttribute(PERF_BUDGET_ALLOW)) continue;
        if (element.hasAttribute(PERF_BUDGET_STILL)) watchStill(element);
        const count = element.childElementCount;
        if (count > budgets.domChildren)
          violate("dom-breadth", describeNode(element), count, budgets.domChildren, " children");
        for (let child = element.firstElementChild; child; child = child.nextElementSibling) stack.push(child);
      }
    };
    const changed = (records: MutationRecord[]) => {
      for (const record of records) {
        if (record.addedNodes.length === 0) continue;
        if (pending.size >= BREADTH_PENDING_LIMIT) {
          overflow = true;
          break;
        }
        const target = record.target as Element;
        // The parent's own count, then each added subtree.
        if (target.nodeType === 1 && target.childElementCount > budgets.domChildren && !allowed(target))
          violate("dom-breadth", describeNode(target), target.childElementCount, budgets.domChildren, " children");
        for (const node of record.addedNodes) if (node.nodeType === 1) pending.add(node as Element);
      }
      if (records.length > 0) timer ??= setTimer(check, BREADTH_DELAY_MS);
    };
    const observer = new (win as unknown as { MutationObserver: typeof MutationObserver }).MutationObserver(changed);
    observer.observe(doc.documentElement, { childList: true, subtree: true });
    flushes.push(() => {
      changed(observer.takeRecords());
      if (timer === undefined) return;
      clearTimer(timer);
      check();
    });
    stops.push(() => {
      observer.disconnect();
      if (timer !== undefined) clearTimer(timer);
    });
    // What was there before we started.
    if (doc.body) timer = setTimer(check, BREADTH_DELAY_MS);
  }

  // layout-shift and long-frame: Chromium's entries, where the engine has them.
  const PO = (win as unknown as { PerformanceObserver?: typeof PerformanceObserver }).PerformanceObserver;
  const types = PO?.supportedEntryTypes ?? [];
  if (PO && types.includes("layout-shift")) {
    let windowStart = 0;
    let windowSum = 0;
    const shifted = (entries: ShiftEntry[]) => {
      for (const entry of entries) {
        if (entry.hadRecentInput || settling() || doc.visibilityState !== "visible") continue;
        for (const source of entry.sources ?? []) {
          if (allowed(source.node)) continue;
          const moved = Math.max(
            Math.abs(source.currentRect.x - source.previousRect.x),
            Math.abs(source.currentRect.y - source.previousRect.y),
            Math.abs(source.currentRect.height - source.previousRect.height),
          );
          if (moved >= budgets.layoutShiftPx)
            violate("layout-shift", describeNode(source.node), moved, budgets.layoutShiftPx, " px");
        }
        if (entry.startTime - windowStart > 1000) {
          windowStart = entry.startTime;
          windowSum = 0;
        }
        windowSum += entry.value;
        if (windowSum > budgets.layoutShiftScore)
          violate(
            "layout-shift",
            `the page (score in 1 s, largest: ${describeNode(entry.sources?.[0]?.node)})`,
            windowSum,
            budgets.layoutShiftScore,
            "",
          );
      }
    };
    const observer = new PO((list) => shifted(list.getEntries() as ShiftEntry[]));
    try {
      observer.observe({ type: "layout-shift", buffered: false });
      stops.push(() => observer.disconnect());
      flushes.push(() => shifted(observer.takeRecords() as ShiftEntry[]));
    } catch {
      // An engine that lists the type and refuses it: no shift budget.
    }
  }
  if (PO && types.includes("long-animation-frame")) {
    const framed = (entries: LoafEntry[]) => {
      if (doc.visibilityState !== "visible") return;
      for (const entry of entries) {
        if (entry.duration <= budgets.longFrameMs || entry.startTime < quietUntil) continue;
        const script = [...(entry.scripts ?? [])].sort((a, b) => b.duration - a.duration)[0];
        const where = script
          ? `${script.sourceFunctionName || script.invoker || "script"} (${(script.sourceURL ?? "").replace(/\?.*$/, "") || "inline"})`
          : "rendering (style, layout or paint)";
        violate("long-frame", where, Math.round(entry.duration), budgets.longFrameMs, " ms");
      }
    };
    const observer = new PO((list) => framed(list.getEntries() as LoafEntry[]));
    try {
      observer.observe({ type: "long-animation-frame", buffered: false });
      stops.push(() => observer.disconnect());
      flushes.push(() => framed(observer.takeRecords() as LoafEntry[]));
    } catch {
      // Same: no frame budget.
    }
  }

  // react-commit: every root, through React's devtools hook (Fast Refresh keeps one in development).
  {
    const scope = win as unknown as { __REACT_DEVTOOLS_GLOBAL_HOOK__?: ReactHook };
    let hook = scope.__REACT_DEVTOOLS_GLOBAL_HOOK__;
    if (!hook) {
      // React reads the hook when it loads: this must run before react-dom does (the dev entry is
      // the page's first script). Fast Refresh, when it loads after, wraps this one.
      let next = 1;
      hook = scope.__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
        renderers: new Map(),
        supportsFiber: true,
        inject: () => next++,
        onScheduleFiberRoot() {},
        onCommitFiberRoot() {},
        onCommitFiberUnmount() {},
      };
    }
    type Seen = { count: number; since: number; inWindow: number; fast?: true; slow?: true };
    const commits = new WeakMap<object, Seen>();
    const onCommit = (root: FiberRoot) => {
      if (!root || typeof root !== "object") return;
      let seen = commits.get(root);
      if (!seen) commits.set(root, (seen = { count: 0, since: 0, inWindow: 0 }));
      seen.count += 1;
      const at = now();
      // Commits in the current one-second window: O(1) per commit.
      if (at - seen.since > 1000) {
        seen.since = at;
        seen.inWindow = 0;
      }
      seen.inWindow += 1;
      if (settling()) return;
      const name = () => `the React root in ${describeNode(root.containerInfo as Node | undefined)}`;
      // Once a root has its warning, its commits cost nothing more for that budget.
      if (!seen.fast && seen.inWindow > budgets.commitsPerSecond) {
        seen.fast = true;
        violate("react-commit", `${name()} (commits in 1 s)`, seen.inWindow, budgets.commitsPerSecond, " commits");
      }
      const ms = root.current?.actualDuration;
      // The first commit mounts the whole root; it is the page's load, not an update.
      if (!seen.slow && seen.count > 1 && typeof ms === "number" && ms > budgets.commitMs) {
        seen.slow = true;
        violate("react-commit", `${name()} (one commit's render)`, ms, budgets.commitMs, " ms");
      }
    };
    const previous = hook.onCommitFiberRoot;
    const wrapped = function (this: unknown, id: number, root: FiberRoot, ...rest: unknown[]) {
      try {
        if (!stopped) onCommit(root);
      } catch (error) {
        if (mode === "throw") throw error;
      }
      return previous?.apply(this, [id, root, ...rest]);
    };
    hook.onCommitFiberRoot = wrapped;
    const own = hook;
    // Fast Refresh may wrap ours later; then `stopped` turns ours into a pass-through.
    stops.push(() => {
      if (own.onCommitFiberRoot === wrapped) own.onCommitFiberRoot = previous;
    });
  }

  const stop = () => {
    if (stopped) return;
    stopped = true;
    for (const run of stops.splice(0)) run();
    win.removeEventListener("pagehide", stop);
  };
  win.addEventListener("pagehide", stop);
  return {
    mode,
    violations,
    flush() {
      if (!stopped) for (const run of flushes) run();
    },
    settle() {
      quietUntil = Math.max(quietUntil, now() + settleMs);
    },
    stop,
  };
}
