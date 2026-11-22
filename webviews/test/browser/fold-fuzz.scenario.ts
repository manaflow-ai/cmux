// l10n-allow-file: synthetic fuzz chats for the fold fuzzer, never shown in the pane.
// The seeded scenario generator behind scripts/fold-fuzz.ts. Leo, 2026-11-22: "you need to simulate tons of
// situations exemplified by various situations and steers coming in at various times and tool calls at various
// times and turn ends at various".
//
// One seed is one Claude turn that ends in the big fold (turnEndFold.ts), every choice drawn from the seed:
// how many calls (1 to 200) and when each lands, the model's chatter between them, subagent blocks, the
// person's steers (mid-stream, mid-tool, mid-fold), how the turn ends (mid-stream, mid-fold, after a recap,
// or settled), the recap and its length, the reader at the bottom or scrolled up, and the split size.
// The same seed always gives the same chat (test/fold-fuzz-scenario.test.ts), so a failing seed replays.
import { sim, type SimScenario, type SimStep } from "../../src/agent-session/acpmux/sim/script";

/// mulberry32: a small, fast, seedable PRNG; the generator draws every choice from it in a fixed order.
export function rng(seed: number) {
  let state = seed >>> 0 || 0x9e3779b9;
  const next = () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let t = state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    /** An integer in [lo, hi]. */
    int: (lo: number, hi: number) => lo + Math.floor(next() * (hi - lo + 1)),
    /** An integer in [lo, hi], log-uniform: small values as likely per octave as large ones. */
    logInt: (lo: number, hi: number) =>
      Math.min(hi, Math.floor(Math.exp(Math.log(lo) + next() * Math.log((hi + 1) / lo)))),
    chance: (p: number) => next() < p,
    pick: <T>(items: readonly T[]): T => items[Math.floor(next() * items.length)]!,
  };
}

/** The split sizes a pane takes (720 x 640 is the full pane the recorder uses). */
export const SPLITS = {
  full: { width: 720, height: 640 },
  half: { width: 360, height: 640 },
  third: { width: 240, height: 640 },
  quarter: { width: 360, height: 320 },
} as const;
export type Split = keyof typeof SPLITS;

/// How the turn ends:
/// - `stream`: 20 ms after the answer's last chunk, while it still streams in;
/// - `fold`: right after the last call's result and a one-line note, while that run's own fold still plays;
/// - `recap`: on the wrap-up call (its recap card), some time after it;
/// - `settled`: well after the answer lands.
export type TurnEnding = "stream" | "fold" | "recap" | "settled";
/// When a steer lands: between two calls (`early`), between the answer's chunks (`stream`), while a call
/// runs (`tool`), or just after the turn's end, as the fold plays (`fold`, a new prompt the person sent).
export type SteerAt = "early" | "stream" | "tool" | "fold";

export type FuzzSpec = {
  seed: number;
  calls: number;
  /** 0: no chatter; else the chance of a note after each call. */
  chatter: number;
  subagents: number;
  steers: SteerAt[];
  ending: TurnEnding;
  /** Sentences in the recap card (0: no recap). */
  recap: number;
  /** Sentences in the closing answer. */
  answer: number;
  viewport: "bottom" | "up";
  /** How far up the reader scrolls (px), when `up`. */
  scrollBy: number;
  split: Split;
  /** Earlier turns above the one that folds. */
  history: number;
};

export type FuzzScenario = {
  spec: FuzzSpec;
  scenario: SimScenario;
  /** The step index of the fold turn's `turn_result`: the turn end the fuzzer measures. */
  foldAt: number;
  /** The first step played on its own clock and sampled; the steps before it fast-forward. */
  windowFrom: number;
};

const SENTENCES = [
  "The retry loop counted its first call as a retry, so it made one call too many.",
  "The jitter now stays inside the cap, and the backoff doubles as before.",
  "The net suite passes on the fleet, all 212 tests.",
  "I also added a case for a zero cap, which used to divide by zero.",
  "The lane's PR is pushed and its checks are running.",
  "Nothing else in the tree calls the old helper.",
  "The follow-up it found is filed with the measurement that showed it.",
  "Two of the three open PRs are green; the third waits on a rebase.",
];
const COMMANDS = [
  "bun test test/net",
  "rg -n attempts src",
  "git status --short",
  "bunx tsc --noEmit -p .",
  "git diff --stat",
];
const KINDS = ["execute", "read", "search", "edit", "execute", "read"] as const;

const text = (r: ReturnType<typeof rng>, sentences: number) =>
  Array.from({ length: sentences }, () => r.pick(SENTENCES)).join(" ");

/** The seed's spec: every choice, in a fixed order, so a seed always draws the same turn. */
export function fuzzSpec(seed: number): FuzzSpec {
  const r = rng(seed);
  const calls = r.logInt(1, 200);
  const chatter = r.chance(0.5) ? r.pick([0.1, 0.2, 0.35, 0.6]) : 0;
  const subagents = r.chance(0.3) ? r.int(1, 2) : 0;
  const steers: SteerAt[] = [];
  const steerCount = r.chance(0.55) ? r.int(1, 3) : 0;
  for (let index = 0; index < steerCount; index += 1) steers.push(r.pick(["early", "stream", "tool", "fold"] as const));
  const ending = r.pick(["stream", "fold", "recap", "settled"] as const);
  const recap = ending === "recap" ? r.int(1, 6) : r.chance(0.25) ? r.int(1, 6) : 0;
  const answer = r.int(1, 8);
  const viewport = r.chance(0.3) ? "up" : "bottom";
  const scrollBy = r.int(120, 640);
  const split = r.pick(Object.keys(SPLITS) as Split[]);
  const history = r.int(1, 3);
  return { seed, calls, chatter, subagents, steers, ending, recap, answer, viewport, scrollBy, split, history };
}

/** The seed's chat. */
export function fuzzScenario(seed: number): FuzzScenario {
  const spec = fuzzSpec(seed);
  // A second stream for the timing, so a spec field added later does not shift every seed's timings.
  const r = rng(seed ^ 0x5bd1e995);
  const b = sim(`fuzz-${seed}`, `Fold fuzz seed ${seed}.`, "claude");
  for (let turn = 0; turn < spec.history; turn += 1) {
    b.prompt(`Earlier question ${turn + 1}: where does the retry helper live?`);
    if (r.chance(0.5)) b.tool(`Read src/net/retry-${turn}.ts`, { kind: "read", ms: r.int(50, 600) });
    b.say(`Earlier answer ${turn + 1}: ${text(r, r.int(1, 3))}`);
    b.turnEnd();
  }
  b.prompt("Run the lanes, fix what they find, and tell me where it all stands.");
  if (r.chance(0.6)) b.think("Starting with the failing suites.", { chunks: r.int(1, 4), chunkMs: r.int(30, 200) });
  // The late steers land in the last calls, so the recorder's window (the steps on their own clock) holds them.
  const late = Math.max(0, spec.calls - r.int(1, 6));
  const tools = spec.steers.filter((at) => at === "tool").length;
  const toolSteerCalls = tally(Array.from({ length: tools }, () => r.int(late, spec.calls - 1)));
  const earlyCalls = spec.steers
    .filter((at) => at === "early")
    .map(() => r.int(0, spec.calls - 1))
    .sort((a, b) => a - b);
  const subagentCalls = Array.from({ length: spec.subagents }, () => r.int(0, spec.calls - 1)).sort((a, b) => a - b);
  const scrollCall = r.int(late, spec.calls);
  let scrolled = false;
  let steerNo = 0;
  const steer = () => `steer ${(steerNo += 1)}: also check the nightly while you're at it`;
  for (let call = 0; call < spec.calls; call += 1) {
    // `<=`: a pair of calls in flight takes two indices, and nothing due at the second is lost.
    for (; subagentCalls.length && subagentCalls[0]! <= call; subagentCalls.shift())
      b.subagent(`Survey the other lanes' open PRs (${call})`, {
        ms: r.int(300, 3_000),
        report: "Three PRs open, two green.",
        tracked: true,
      });
    for (; earlyCalls.length && earlyCalls[0]! <= call; earlyCalls.shift())
      b.steer(steer(), { readMs: r.int(100, 1_200), after: r.int(30, 600) });
    if (spec.viewport === "up" && !scrolled && call >= scrollCall) {
      b.reader({ scrollBy: -spec.scrollBy }, r.int(30, 400));
      scrolled = true;
    }
    const kind = r.pick(KINDS);
    const title =
      kind === "read" || kind === "edit"
        ? `${kind === "read" ? "Read" : "Edit"} src/lane/part-${call}.ts`
        : `${r.pick(COMMANDS)} # ${call}`;
    const options = {
      kind,
      ms: r.logInt(40, 3_000),
      ...(r.chance(0.1) && { status: "failed" as const, output: "1 fail" }),
      ...(kind === "edit" && { path: `src/lane/part-${call}.ts` }),
    };
    const after = r.logInt(20, 900);
    if (toolSteerCalls.has(call)) {
      // Mid-tool: the call starts, the steers land while it runs, then its result.
      const id = b.nextCallId();
      b.tool(title, { ...options, open: true }, after);
      for (let n = 0; n < toolSteerCalls.get(call)!; n += 1)
        b.steer(steer(), { readMs: r.int(100, 800), after: r.int(20, Math.max(21, options.ms - 20)) });
      b.toolEnd(id, { ...options, ms: r.int(20, 600) });
    } else if (r.chance(0.08) && call < spec.calls - 1 && !toolSteerCalls.has(call + 1)) {
      // Two calls in flight at once: the second starts before the first ends.
      const id = b.nextCallId();
      b.tool(title, { ...options, open: true }, after);
      call += 1;
      b.tool(`${r.pick(COMMANDS)} # ${call}`, { ms: r.logInt(40, 1_500) }, r.int(10, 200));
      b.toolEnd(id, { ms: r.int(10, 400) });
    } else b.tool(title, options, after);
    if (spec.chatter && call < spec.calls - 1 && r.chance(spec.chatter))
      b.say(`Step ${call + 1} of ${spec.calls}: ${text(r, r.int(1, 3))}`, {
        chunks: r.int(1, 4),
        chunkMs: r.int(30, 150),
        after: r.int(50, 600),
      });
  }
  if (spec.viewport === "up" && !scrolled) b.reader({ scrollBy: -spec.scrollBy }, r.int(30, 400));
  const streamSteers = spec.steers.filter((at) => at === "stream").length;
  const foldSteers = spec.steers.filter((at) => at === "fold").length;
  const recapCard = () =>
    b.tool("mcp__acpmux__wrap_up", {
      kind: "other",
      ms: r.int(30, 400),
      rawInput: {
        recap: text(r, spec.recap),
        ...(r.chance(0.5) && { ask: "Should I open a PR for this?" }),
        actions: ["Yes, open PR", "Not now"].slice(0, r.int(0, 2)),
      },
    });
  if (spec.ending === "fold") {
    // The turn ends while the last run of calls folds under the one note after it.
    b.say(text(r, 1), { chunks: 1, after: r.int(20, 200) });
    // No answer streams here: a mid-stream steer lands on the note's heels.
    for (let n = 0; n < streamSteers; n += 1) b.steer(steer(), { readMs: r.int(50, 400), after: r.int(10, 120) });
    if (spec.recap) recapCard();
    b.turnEnd("completed", r.int(16, 160));
  } else {
    const answer = text(r, spec.answer);
    const chunks = Math.max(1, Math.min(24, Math.ceil(answer.length / r.int(30, 90))));
    const chunkMs = r.int(20, 150);
    const steerAt = tally(Array.from({ length: streamSteers }, () => r.int(0, chunks - 1)));
    // `say` chunks on word boundaries; stream the parts one by one so a steer can land between two of them.
    const words = answer.split(/(?<=\s)/);
    const per = Math.max(1, Math.ceil(words.length / chunks));
    for (let index = 0, part = 0; index < words.length; index += per, part += 1) {
      b.say(words.slice(index, index + per).join(""), { chunks: 1, after: part === 0 ? r.int(50, 600) : chunkMs });
      for (let n = 0; n < (steerAt.get(part) ?? 0); n += 1)
        b.steer(steer(), { readMs: r.int(100, 800), after: r.int(10, chunkMs) });
    }
    if (spec.ending === "stream") {
      if (spec.recap) recapCard();
      b.turnEnd("completed", 20);
    } else if (spec.ending === "recap") {
      recapCard();
      b.turnEnd("completed", r.int(100, 1_500));
    } else {
      if (spec.recap) recapCard();
      b.turnEnd("completed", r.int(400, 1_500));
    }
  }
  const built = b.build();
  const foldAt = lastIndex(built.steps, (step) => step.label === "turn_result");
  // Mid-fold: the person's next message lands as the fold plays, and the next turn starts.
  if (foldSteers) {
    for (let index = 0; index < foldSteers; index += 1) {
      b.prompt(steer(), r.int(0, 400));
      if (r.chance(0.5)) b.say(text(r, 1), { chunks: 2, chunkMs: 60, after: r.int(50, 400) });
    }
  }
  const scenario = b.build();
  // The window: the last 30 steps before the turn's end, and any late steer or scroll before them.
  const firstLate = scenario.steps.findIndex(
    (step, index) =>
      index > 0 &&
      (step.label.startsWith("steer") || step.type === "reader") &&
      step.at >= scenario.steps[Math.max(0, foldAt - 60)]!.at,
  );
  const windowFrom = Math.max(0, Math.min(foldAt - 30, firstLate < 0 ? foldAt : firstLate - 2));
  return { spec, scenario, foldAt, windowFrom };
}

/** How many times each value comes up. */
function tally(values: number[]) {
  const counts = new Map<number, number>();
  for (const value of values) counts.set(value, (counts.get(value) ?? 0) + 1);
  return counts;
}

function lastIndex(steps: readonly SimStep[], match: (step: SimStep) => boolean) {
  for (let index = steps.length - 1; index >= 0; index -= 1) if (match(steps[index]!)) return index;
  return -1;
}
