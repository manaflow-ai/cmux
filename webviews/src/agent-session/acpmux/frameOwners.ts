// `cmux app chat perf`'s frame owners: which code in the page asks for frames while a capture runs.
// The capture's own frame loop runs every display frame (that is how it counts frames), so its
// frame count is the display's rate whatever the page does: 601 frames in 5 s on a 120 Hz display
// is the capture, not the chat. These owners say what else asked, by code location:
//   - frames: every requestAnimationFrame call, by its caller;
//   - timers: every setTimeout or setInterval of 50 ms or less (a frame-paced timer), by its caller;
//   - animate: every Element.animate call, by its caller;
//   - animations: the animations running when the window ends (CSS, transitions, Web Animations),
//     by name and target element (tag and class names), with their iteration count;
//   - page_frames: in how many of the capture's frames page code asked for another one.
// A caller is the first stack frame past the wrapper, as a script URL's path and line:column. In a
// release build that is a position in pane.js or a chunk; the build's site table
// (chunks/frame-sites.js, written by scripts/agent-pane/frameSites.mjs from the bundle's source
// maps) names the source file there. The page loads that table only once a capture has ended.
//
// It costs nothing outside a capture: the wrappers exist only for the window and the page's own
// functions are put back when it ends, also when it throws. It reports only code locations, class
// names and counts, never text from the chat, so a paired or remote caller sees no transcript.

/** Timers at or under this delay count as frame-paced. */
export const SHORT_TIMER_MS = 50;
/** At most this many call sites per kind; the rest add up under `(other)`. */
export const MAX_SITES = 24;
/** At most this many running animation groups in a report. */
export const MAX_ANIMATIONS = 16;

/** A stack's caller as `{ url, line, column }`; null when the line has no position. */
export function stackPosition(line: string): { url: string; line: number; column: number } | null {
  const match = /(?:\(|@|\s)((?:[a-z][\w+.-]*:\/\/?[^\s()]*|\/[^\s()]*)):(\d+):(\d+)\)?\s*$/i.exec(line);
  if (!match) return null;
  return { url: match[1], line: Number(match[2]), column: Number(match[3]) };
}

/** A script URL as a path under its origin, with no query or fragment (`pane.js`, `src/x.ts`). */
export function scriptPath(url: string): string {
  const cut = url.search(/[?#]/);
  const bare = cut < 0 ? url : url.slice(0, cut);
  const origin = /^[a-z][\w+.-]*:\/\/[^/]*\//i.exec(bare);
  if (origin) return bare.slice(origin[0].length);
  return bare.replace(/^\/+/, "");
}

/** The caller of the wrapper that made `stack`: its third line (the error, the wrapper, the caller). */
export function callerSite(stack: string | undefined): string {
  const lines = (stack ?? "").split("\n");
  // V8 and Bun start with the message line ("Error"); JavaScriptCore does not.
  const frames = /^\s*(at\s|[^\s@]*@)/.test(lines[0] ?? "") ? lines : lines.slice(1);
  const position = stackPosition(frames[1] ?? "");
  if (!position) return "(unknown)";
  return `${scriptPath(position.url)}:${position.line}:${position.column}`;
}

/** The build's site table: per output script, its module boundaries as [line, column, source] triples. */
export type SiteTable = { sources: readonly string[]; files: Readonly<Record<string, readonly number[]>> };

/**
 * The source file a bundle position (`pane.js:1:4567`, 1-based line and column) belongs to, from the
 * site table; null when the table does not know the script.
 */
export function resolveSite(table: SiteTable | null, site: string): string | null {
  if (!table) return null;
  const match = /^(.*):(\d+):(\d+)$/.exec(site);
  if (!match) return null;
  const marks = table.files[match[1]];
  if (!marks?.length) return null;
  const line = Number(match[2]) - 1;
  const column = Number(match[3]) - 1;
  // The last boundary at or before the position.
  let low = 0;
  let high = marks.length / 3 - 1;
  let found = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    const markLine = marks[mid * 3];
    const markColumn = marks[mid * 3 + 1];
    if (markLine < line || (markLine === line && markColumn <= column)) {
      found = mid;
      low = mid + 1;
    } else high = mid - 1;
  }
  return found < 0 ? null : (table.sources[marks[found * 3 + 2]] ?? null);
}

/** A source path for a site the table does not know: a dev server's own module path, else none. */
function ownFile(site: string): string | null {
  const path = site.replace(/:\d+:\d+$/, "");
  return /\.(tsx?|jsx?|mjs)$/.test(path) && !/(^|\/)(pane|chunks\/[^/]+)\.js$/.test(path) ? path : null;
}

type Tally = Map<string, number>;

function bump(tally: Tally, key: string) {
  const known = tally.get(key);
  if (known !== undefined) tally.set(key, known + 1);
  else if (tally.size < MAX_SITES) tally.set(key, 1);
  else tally.set("(other)", (tally.get("(other)") ?? 0) + 1);
}

export type OwnerSite = { file: string | null; at: string; count: number; per_s: number };

function sites(tally: Tally, seconds: number, table: SiteTable | null): OwnerSite[] {
  return [...tally.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([at, count]) => ({
      file: at === "(other)" ? null : (resolveSite(table, at) ?? ownFile(at)),
      at,
      count,
      per_s: Math.round((count / Math.max(seconds, 0.001)) * 10) / 10,
    }));
}

/** An element as its tag and first two class names: code's names, never the element's text. */
export function describeTarget(target: unknown): string {
  const element = target as { tagName?: unknown; classList?: Iterable<string> } | null;
  if (!element || typeof element.tagName !== "string") return "?";
  const classes = element.classList ? [...element.classList].slice(0, 2) : [];
  return [element.tagName.toLowerCase(), ...classes].join(".");
}

/** The parts of an `Animation` the report reads. */
export type AnimationLike = {
  playState?: string;
  id?: string;
  animationName?: string;
  transitionProperty?: string;
  effect?: { target?: unknown; getComputedTiming?: () => { iterations?: number } } | null;
};

export type RunningAnimation = { name: string; target: string; iterations: number | "infinite"; count: number };

/** Running animations grouped by name, target and iteration count, most first. */
export function runningAnimations(animations: readonly AnimationLike[]): RunningAnimation[] {
  const groups = new Map<string, RunningAnimation>();
  for (const animation of animations) {
    if (animation.playState !== "running") continue;
    const name = animation.animationName
      ? animation.animationName
      : animation.transitionProperty
        ? `transition ${animation.transitionProperty}`
        : animation.id || "animation";
    const target = describeTarget(animation.effect?.target ?? null);
    const raw = animation.effect?.getComputedTiming?.().iterations ?? 1;
    const iterations = Number.isFinite(raw) ? raw : "infinite";
    const key = `${name}\u0000${target}\u0000${iterations}`;
    const group = groups.get(key);
    if (group) group.count += 1;
    else groups.set(key, { name, target, iterations, count: 1 });
  }
  return [...groups.values()].sort((a, b) => b.count - a.count).slice(0, MAX_ANIMATIONS);
}

/** What the tally wraps; tests pass a fake. */
export type OwnersHost = {
  requestAnimationFrame: (callback: FrameRequestCallback) => number;
  setTimeout: (handler: TimerHandler, timeout?: number, ...rest: unknown[]) => unknown;
  setInterval: (handler: TimerHandler, timeout?: number, ...rest: unknown[]) => unknown;
};
export type OwnersEnv = {
  host: OwnersHost;
  /** `Element.prototype`, or undefined where the page has no `animate`. */
  animateHost?: { animate?: (...args: unknown[]) => unknown };
  animations(): readonly AnimationLike[];
  /** The build's site table, or null (a dev server, a test, or a build without one). */
  loadSites(): Promise<SiteTable | null>;
};

let siteTable: Promise<SiteTable | null> | undefined;

/** The page's environment: its window, `Element.prototype`, and the bundle's site table. */
export function browserOwnersEnv(): OwnersEnv {
  return {
    host: window as unknown as OwnersHost,
    animateHost:
      typeof Element !== "undefined" ? (Element.prototype as unknown as OwnersEnv["animateHost"]) : undefined,
    animations: () => (typeof document.getAnimations === "function" ? document.getAnimations() : []) as AnimationLike[],
    loadSites() {
      siteTable ??= (async () => {
        try {
          // Beside pane.js (the document's folder); a dev server and the gallery have none.
          // A build output, not a source module: no test's import graph runs through it.
          const url = new URL("chunks/frame-sites.js", document.baseURI).href;
          const module = (await import(/* @vite-ignore */ url)) as { default?: SiteTable }; // webviews-affected: runtime-url
          return module.default?.files ? module.default : null;
        } catch {
          return null;
        }
      })();
      return siteTable;
    },
  };
}

export type FrameOwnersReport = {
  page_frames: number;
  frames: OwnerSite[];
  timers: OwnerSite[];
  animate: OwnerSite[];
  animations: RunningAnimation[];
  sites_resolved: boolean;
};

export type FrameOwners = {
  /** The capture's own frame began: the next page request counts toward a new frame. */
  frame(): void;
  /** Puts the page's functions back; idempotent. */
  restore(): void;
  /** Restores, then reports over `seconds`. */
  report(seconds: number): Promise<FrameOwnersReport>;
};

/** Starts counting the page's frame, short-timer and animate callers until `restore` or `report`. */
export function startFrameOwners(env: OwnersEnv = browserOwnersEnv()): FrameOwners {
  const frames: Tally = new Map();
  const timers: Tally = new Map();
  const animate: Tally = new Map();
  let frameIndex = 0;
  let markedFrame = -1;
  let pageFrames = 0;
  const host = env.host;
  // Own properties to put back as they were (a page that never set one gets it deleted, so the
  // prototype's function shows through again).
  const saved: { target: object; key: string; own: boolean; value: unknown }[] = [];
  const wrap = (target: object, key: string, make: (original: (...args: unknown[]) => unknown) => unknown) => {
    const original = (target as Record<string, unknown>)[key];
    if (typeof original !== "function") return;
    saved.push({ target, key, own: Object.prototype.hasOwnProperty.call(target, key), value: original });
    (target as Record<string, unknown>)[key] = make(original as (...args: unknown[]) => unknown);
  };
  wrap(
    host,
    "requestAnimationFrame",
    (original) =>
      function requestAnimationFrame(this: unknown, ...args: unknown[]) {
        bump(frames, callerSite(new Error().stack));
        if (markedFrame !== frameIndex) {
          markedFrame = frameIndex;
          pageFrames += 1;
        }
        return Reflect.apply(original, host, args);
      },
  );
  for (const key of ["setTimeout", "setInterval"] as const)
    wrap(
      host,
      key,
      (original) =>
        function timer(this: unknown, ...args: unknown[]) {
          const delay = Number(args[1] ?? 0);
          if (!(delay > SHORT_TIMER_MS))
            bump(timers, `${key === "setTimeout" ? "timeout" : "interval"} ${callerSite(new Error().stack)}`);
          return Reflect.apply(original, host, args);
        },
    );
  if (env.animateHost)
    wrap(
      env.animateHost,
      "animate",
      (original) =>
        function animateCall(this: unknown, ...args: unknown[]) {
          bump(animate, callerSite(new Error().stack));
          return Reflect.apply(original, this, args);
        },
    );
  let restored = false;
  const restore = () => {
    if (restored) return;
    restored = true;
    for (const { target, key, own, value } of saved.reverse()) {
      if (own) (target as Record<string, unknown>)[key] = value;
      else delete (target as Record<string, unknown>)[key];
    }
  };
  return {
    frame() {
      frameIndex += 1;
    },
    restore,
    async report(seconds) {
      restore();
      let animations: RunningAnimation[] = [];
      try {
        animations = runningAnimations(env.animations());
      } catch {
        animations = [];
      }
      const needsTable = [...frames.keys(), ...timers.keys(), ...animate.keys()].some((site) =>
        /(^|\s)(pane|chunks\/[^\s/]+)\.js:\d+:\d+$/.test(site),
      );
      const table = needsTable ? await env.loadSites() : null;
      const timerSites = sites(timers, seconds, null).map((site) => {
        const space = site.at.indexOf(" ");
        const at = space < 0 ? site.at : site.at.slice(space + 1);
        return { ...site, file: site.at === "(other)" ? null : (resolveSite(table, at) ?? ownFile(at)) };
      });
      return {
        page_frames: pageFrames,
        frames: sites(frames, seconds, table),
        timers: timerSites,
        animate: sites(animate, seconds, table),
        animations,
        sites_resolved: table !== null,
      };
    },
  };
}
