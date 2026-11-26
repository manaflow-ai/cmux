// The power-user input stress harness's plan and judge (power-user-bursts.browser.test.ts).
//
// Leo, 2026-11-22: "you guys also need to be testing flicks of extremely fast input for scrolling and
// resizing/mouse movement and typing/pasting/switching workspaces around. we need to test like power
// users more often."
//
// A seed makes the whole run: which bursts, in what order, which of them overlap, and every delta,
// size, key and gap inside them. The same seed replays the same input, so a breach is filed with its
// seed and `POWER_USER_SEED=<seed> bun test test/power-user-bursts.browser.test.ts` brings it back.
// Everything here is pure (no page), so the unit test holds the plan and the judge still.

/** Input classes the harness drives and reports on, each with its own numbers. */
export const BURST_KINDS = [
  "flick",
  "momentum",
  "resize",
  "sweep",
  "type",
  "paste",
  "image",
  "switch",
  "send",
] as const;
export type BurstKind = (typeof BURST_KINDS)[number];

/** Whether a "follow reversed" stray (followJudge.ts) at `frame` was the input's: a wheel turned that way within
 *  `window` frames before it. `wheels[f]` holds the signs of the wheel deltas that arrived before frame f painted.
 *  Rows move down (dy > 0) when the wheel scrolls up (deltaY < 0). */
export function reversalFromWheel(wheels: readonly number[][], frame: number, dy: number, window = 6): boolean {
  for (let at = Math.max(0, frame - window); at <= Math.min(wheels.length - 1, frame + 1); at += 1)
    if ((wheels[at] ?? []).some((sign) => sign === -Math.sign(dy))) return true;
  return false;
}

/** Kinds that change the composer's draft: never two at once, and never beside a session switch,
 *  so the draft each one expects is its own (a switch shows another session's draft). */
const DRAFT_KINDS: ReadonlySet<BurstKind> = new Set(["type", "paste", "image", "send"]);
/** Kinds that move the layout on purpose: the shift judge reads only the settle after them. */
export const LAYOUT_KINDS: ReadonlySet<BurstKind> = new Set(["resize", "switch", "send"]);

export type WheelStep = { dy: number; gapMs: number };
export type Burst =
  | { kind: "flick"; at: [number, number]; steps: WheelStep[] }
  | { kind: "momentum"; at: [number, number]; steps: WheelStep[] }
  | { kind: "resize"; sizes: { width: number; height: number; gapMs: number }[] }
  | { kind: "sweep"; points: [number, number][]; stepsPer: number }
  | { kind: "type"; text: string; gapMs: number }
  | { kind: "paste"; chars: number }
  | { kind: "image"; width: number; height: number }
  | { kind: "switch"; sessions: number[]; gapMs: number }
  | { kind: "send"; text: string; switchAfterMs: number };

/** One step of the run: bursts that start together and overlap. */
export type Wave = { bursts: Burst[] };

/** mulberry32: small, fast, and the same in every engine and runtime. */
export function rng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const KEYS = "abcdefghijklmnopqrstuvwxyz     ,.;'-=0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ()[]{}<>?!";

/** The run a seed makes: `waves` waves for a `width` x `height` page with `sessions` sessions to switch between. */
export function planRun(
  seed: number,
  options: { waves: number; width: number; height: number; sessions: number },
): Wave[] {
  const random = rng(seed);
  const int = (low: number, high: number) => low + Math.floor(random() * (high - low + 1));
  const pick = <T>(values: readonly T[]): T => values[Math.floor(random() * values.length)]!;
  const point = (): [number, number] => [
    int(40, options.width - 40),
    // The transcript, above the composer (the bottom 180 px).
    int(40, Math.max(60, options.height - 180)),
  ];
  const make = (kind: BurstKind): Burst => {
    switch (kind) {
      case "flick": {
        // A wheel burst: notches 4-16 ms apart, mostly up (back through history), sometimes a
        // reversal halfway, as a hand that flicks and catches.
        const up = random() < 0.7 ? -1 : 1;
        const reverse = random() < 0.3;
        const count = int(6, 30);
        return {
          kind,
          at: point(),
          steps: Array.from({ length: count }, (_, index) => ({
            dy: (reverse && index > count / 2 ? -up : up) * int(40, 480),
            gapMs: int(4, 16),
          })),
        };
      }
      case "momentum": {
        // A trackpad fling: one large delta decaying every 8 ms, as the OS's momentum phase posts it.
        const sign = random() < 0.6 ? -1 : 1;
        let dy = int(80, 260);
        const steps: WheelStep[] = [];
        while (dy >= 1 && steps.length < 120) {
          steps.push({ dy: sign * Math.round(dy), gapMs: 8 });
          dy *= 0.9 + random() * 0.06;
        }
        return { kind, at: point(), steps };
      }
      case "resize":
        // A window edge dragged fast, both ways, through narrow and wide.
        return {
          kind,
          sizes: Array.from({ length: int(4, 18) }, () => ({
            width: int(360, 1600),
            height: int(420, 1100),
            gapMs: int(0, 24),
          })),
        };
      case "sweep":
        // The pointer swept across rows, chips and buttons: hover cards, row actions, scroll rails.
        return { kind, points: Array.from({ length: int(3, 10) }, point), stepsPer: int(4, 24) };
      case "type": {
        // 15 to 60 keys a second.
        const length = int(20, 90);
        return {
          kind,
          text: Array.from({ length }, () => pick(KEYS.split(""))).join(""),
          gapMs: Math.round(1000 / int(15, 60)),
        };
      }
      case "paste":
        return { kind, chars: pick([2_000, 20_000, 200_000, 600_000]) };
      case "image":
        return { kind, width: pick([64, 1200, 3456]), height: pick([64, 900, 2234]) };
      case "switch":
        return {
          kind,
          sessions: Array.from({ length: int(3, 10) }, () => int(0, options.sessions - 1)),
          gapMs: int(0, 140),
        };
      case "send":
        return {
          kind,
          text: `burst ${seed}-${int(0, 1e6)} ${Array.from({ length: int(5, 40) }, () => pick(KEYS.split(""))).join("")}`,
          switchAfterMs: int(0, 120),
        };
    }
  };
  const waves: Wave[] = [];
  for (let index = 0; index < options.waves; index += 1) {
    // One to three bursts at once; a draft kind never beside another draft kind or a switch.
    const width = int(1, 3);
    const bursts: Burst[] = [];
    let drafts = false;
    let switches = false;
    for (let tries = 0; bursts.length < width && tries < 12; tries += 1) {
      const kind = pick(BURST_KINDS);
      const draft = DRAFT_KINDS.has(kind);
      if (draft && (drafts || switches)) continue;
      if (kind === "switch" && (drafts || switches)) continue;
      if (bursts.some((burst) => burst.kind === kind)) continue;
      drafts ||= draft;
      switches ||= kind === "switch";
      bursts.push(make(kind));
    }
    waves.push({ bursts });
  }
  return waves;
}

export function percentile(values: readonly number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))]!;
}

const round = (value: number) => Math.round(value * 10) / 10;

/** What one input class measured over a run. */
export type ClassNumbers = {
  bursts: number;
  frames: number;
  frame_p95_ms: number;
  frame_p99_ms: number;
  /** Frames over 50 ms (a long frame: three refreshes missed). */
  long_frames: number;
  worst_frame_ms: number;
  /** Input event to the first frame painted after it. */
  input_to_paint_p95_ms: number;
  input_to_paint_p99_ms: number;
  inputs: number;
  /** Key press to the frame its character first paints in the composer (type bursts). */
  caret_lag_p95_ms?: number;
  /** Keys typed that never reached the draft, or reached it out of order. */
  dropped_keys?: number;
  reordered?: boolean;
  /** Stray moves (followJudge.ts) over 1 px that the input did not cause, and the worst in px. */
  stray_frames: number;
  stray_worst_px: number;
  /** Frames where the transcript left over half its view empty, or the pane drew nothing. */
  blank_frames: number;
};

export type BurstRecord = {
  kind: BurstKind;
  wave: number;
  frameMs: number[];
  inputToPaintMs: number[];
  caretLagMs?: number[];
  droppedKeys?: number;
  reordered?: boolean;
  strayFrames: number;
  strayWorstPx: number;
  stray?: unknown[];
  blankFrames: number;
};

export function classNumbers(records: readonly BurstRecord[]): Partial<Record<BurstKind, ClassNumbers>> {
  const out: Partial<Record<BurstKind, ClassNumbers>> = {};
  for (const kind of BURST_KINDS) {
    const mine = records.filter((record) => record.kind === kind);
    if (mine.length === 0) continue;
    const frames = mine.flatMap((record) => record.frameMs);
    const inputs = mine.flatMap((record) => record.inputToPaintMs);
    const caret = mine.flatMap((record) => record.caretLagMs ?? []);
    out[kind] = {
      bursts: mine.length,
      frames: frames.length,
      frame_p95_ms: round(percentile(frames, 0.95)),
      frame_p99_ms: round(percentile(frames, 0.99)),
      long_frames: frames.filter((ms) => ms > 50).length,
      worst_frame_ms: round(Math.max(0, ...frames)),
      input_to_paint_p95_ms: round(percentile(inputs, 0.95)),
      input_to_paint_p99_ms: round(percentile(inputs, 0.99)),
      inputs: inputs.length,
      ...(caret.length > 0 && {
        caret_lag_p95_ms: round(percentile(caret, 0.95)),
        dropped_keys: mine.reduce((sum, record) => sum + (record.droppedKeys ?? 0), 0),
        reordered: mine.some((record) => record.reordered),
      }),
      stray_frames: mine.reduce((sum, record) => sum + record.strayFrames, 0),
      stray_worst_px: round(Math.max(0, ...mine.map((record) => record.strayWorstPx))),
      blank_frames: mine.reduce((sum, record) => sum + record.blankFrames, 0),
    };
  }
  return out;
}

/** The budgets a run must keep. Frame budgets are for a headless engine on a shared CI worker
 *  (rAF at 60 Hz): p95 within two refreshes, p99 within four. */
export type Budgets = {
  frame_p95_ms: number;
  frame_p99_ms: number;
  /** Long frames (> 50 ms) as a share of the class's frames. */
  long_frame_share: number;
  input_to_paint_p95_ms: number;
  caret_lag_p95_ms: number;
  stray_px: number;
};

export const DEFAULT_BUDGETS: Budgets = {
  frame_p95_ms: 33.4,
  frame_p99_ms: 66.8,
  long_frame_share: 0.03,
  input_to_paint_p95_ms: 50,
  caret_lag_p95_ms: 50,
  stray_px: 1,
};

/** Classes whose own work is allowed long frames: a 600 KB paste or a 3456 px image decodes once. */
const HEAVY_KINDS: ReadonlySet<BurstKind> = new Set(["paste", "image", "resize"]);

/** The timing breaches: frame times, input to paint and caret lag. A shared CI worker's timing swings run to run,
 *  so the PR lane reports them and the nightly perf-cron rows (webui.power_user.*) track them on a steady host; the
 *  PR lane fails on the rest (blank frames, stray moves, dropped or reordered keys, console errors), which no
 *  runner's speed excuses. POWER_USER_GATE_TIMING=1 fails on them too. */
export const TIMING_WHATS: ReadonlySet<string> = new Set([
  "frame_p95_ms",
  "frame_p99_ms",
  "long_frame_share",
  "input_to_paint_p95_ms",
  "caret_lag_p95_ms",
]);

export type Breach = { kind: BurstKind | "console"; what: string; value: number | string; budget: number | string };

/** The frames the page painted with the reply streaming and no input: the runner's own floor. */
export type Baseline = { frame_p95_ms: number; frame_p99_ms: number; long_frame_share: number };

/** How far over the idle stream's own frames a class may go before its frames are its input's fault: a shared CI
 *  worker paints a headless page far slower than a Mac, and the absolute budget alone would judge the runner. */
export const BASELINE_FACTOR = 1.5;

export function judge(
  numbers: Partial<Record<BurstKind, ClassNumbers>>,
  consoleErrors: readonly string[],
  budgets: Budgets = DEFAULT_BUDGETS,
  baseline?: Baseline,
): Breach[] {
  const breaches: Breach[] = [];
  const over = (kind: BurstKind, what: string, value: number | undefined, budget: number) => {
    if (value !== undefined && value > budget)
      breaches.push({ kind, what, value, budget: Math.round(budget * 1000) / 1000 });
  };
  const floor = (budget: number, idle: number | undefined) => Math.max(budget, (idle ?? 0) * BASELINE_FACTOR);
  for (const [kind, n] of Object.entries(numbers) as [BurstKind, ClassNumbers][]) {
    const heavy = HEAVY_KINDS.has(kind);
    if (!heavy) {
      over(kind, "frame_p95_ms", n.frame_p95_ms, floor(budgets.frame_p95_ms, baseline?.frame_p95_ms));
      over(kind, "frame_p99_ms", n.frame_p99_ms, floor(budgets.frame_p99_ms, baseline?.frame_p99_ms));
      over(
        kind,
        "long_frame_share",
        n.frames > 0 ? n.long_frames / n.frames : 0,
        floor(budgets.long_frame_share, baseline?.long_frame_share),
      );
      over(
        kind,
        "input_to_paint_p95_ms",
        n.input_to_paint_p95_ms,
        floor(budgets.input_to_paint_p95_ms, baseline?.frame_p95_ms),
      );
    }
    over(kind, "caret_lag_p95_ms", n.caret_lag_p95_ms, budgets.caret_lag_p95_ms);
    over(kind, "dropped_keys", n.dropped_keys, 0);
    if (n.reordered) breaches.push({ kind, what: "reordered", value: "yes", budget: "no" });
    over(kind, "stray_worst_px", n.stray_worst_px, budgets.stray_px);
    over(kind, "blank_frames", n.blank_frames, 0);
  }
  // One breach per distinct message (ids and numbers folded), with how often it came.
  const counts = new Map<string, number>();
  for (const error of consoleErrors) {
    const key = error.slice(0, 400).replace(/\d+/g, "N");
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  for (const [error, count] of counts)
    breaches.push({ kind: "console", what: "error", value: `${count}x ${error.slice(0, 300)}`, budget: "none" });
  return breaches;
}

/** How a typed run reached the draft: keys missing from it, and whether what arrived is out of order. */
export function draftDiff(expected: string, actual: string): { dropped: number; reordered: boolean } {
  // The longest common subsequence: keys in order. What is in `expected` and not in it was dropped
  // or moved; when `actual` holds every key but not in order, the run reordered.
  const a = expected;
  const b = actual;
  if (a === b) return { dropped: 0, reordered: false };
  const row = Array.from({ length: b.length + 1 }, () => 0);
  for (let i = 1; i <= a.length; i += 1) {
    let previous = 0;
    for (let j = 1; j <= b.length; j += 1) {
      const kept = row[j]!;
      row[j] = a[i - 1] === b[j - 1] ? previous + 1 : Math.max(row[j]!, row[j - 1]!);
      previous = kept;
    }
  }
  const inOrder = row[b.length]!;
  const count = (text: string) => {
    const counts = new Map<string, number>();
    for (const char of text) counts.set(char, (counts.get(char) ?? 0) + 1);
    return counts;
  };
  const want = count(a);
  const got = count(b);
  let present = 0;
  for (const [char, n] of want) present += Math.min(n, got.get(char) ?? 0);
  return { dropped: a.length - present, reordered: present > inOrder };
}

/** Breaches already filed, by `engine kind what`: reported, not failed, until the fix lands. */
export const KNOWN: Record<string, string> = {
  "console Encountered two children with the same key": "manaflow-ai/cmux#50478",
  // A wave's blank frames and strays count against every input kind in the wave, and which kinds share a
  // wave with the blank or the stray moves run to run (the same seed put blank frames on "switch" and "send"
  // in one run and not the next), so these two are filed for every kind (`*`) until #50479 and #50480 land.
  "chromium * blank_frames": "manaflow-ai/cmux#50479",
  "webkit * blank_frames": "manaflow-ai/cmux#50479",
  "chromium * stray_worst_px": "manaflow-ai/cmux#50480",
  "webkit * stray_worst_px": "manaflow-ai/cmux#50480",
  "console ResizeObserver loop completed": "manaflow-ai/cmux#50481",
};

/** The issue a breach is already filed as: `engine kind what` (`engine * what` for any kind), or a
 *  `console <substring>` of the message. */
export function knownBreach(engine: string, breach: Breach): string | undefined {
  if (breach.kind === "console")
    return Object.entries(KNOWN).find(
      ([key]) => key.startsWith("console ") && String(breach.value).includes(key.slice(8)),
    )?.[1];
  return KNOWN[`${engine} ${breach.kind} ${breach.what}`] ?? KNOWN[`${engine} * ${breach.what}`];
}
