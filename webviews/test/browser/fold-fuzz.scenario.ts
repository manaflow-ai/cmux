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
import { sim, type ReaderAction, type SimScenario, type SimStep } from "../../src/agent-session/acpmux/sim/script";

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
  /** A wide pane (hq#18554: "narrow and wide panes"). */
  wide: { width: 1280, height: 800 },
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
  /** hq#18554 ask 3's axes (`fuzzAxes`), drawn from their own stream. */
  axes: FuzzAxes;
};

/// The axes hq#18554 ask 3 adds (Leo, 2026-11-22: "EVERY POSSIBLE CASE, NO MATTER HOW WILD"), drawn from
/// their own stream so every earlier field of a seed draws as before:
/// - `send`: the person's message of 1, 5, 30 or 300 lines, with or without attachments, sent as the
///   next prompt right after the turn's end (`next`) or as a steer while the answer streams (`steer`);
/// - `tailTools`: calls that land after the answer, just before the turn ends (the "dingleberries");
/// - `tail`: the turn ends plainly, after a compaction, or with a queued message that is sent the moment it ends;
/// - `notice`: after the turn, a notification starts a turn whose only activity is one or two calls
///   (`notice-turn`), or a land notice and a call sending a message (`land-send`: the "Sending message" row);
/// - `background`: a background command started in the turn completes after it ends;
/// - `load`: the page's CPU slowed this many times (1: none);
/// - `wide`: the pane is 1280 px wide (it overrides `split`).
export type FuzzAxes = {
  send: { lines: 1 | 5 | 30 | 300; attach: boolean; at: "next" | "steer" } | undefined;
  tailTools: number;
  tail: "plain" | "compaction" | "queued";
  notice: "none" | "notice-turn" | "land-send";
  background: boolean;
  load: 1 | 4;
  wide: boolean;
};

export function fuzzAxes(seed: number): FuzzAxes {
  const r = rng(seed ^ 0x2c1b3c6d);
  const send = r.chance(0.6)
    ? {
        lines: r.pick([1, 5, 30, 300] as const),
        attach: r.chance(0.35),
        at: r.pick(["next", "steer"] as const),
      }
    : undefined;
  return {
    send,
    tailTools: r.chance(0.35) ? r.int(1, 3) : 0,
    tail: r.pick(["plain", "plain", "compaction", "queued"] as const),
    notice: r.pick(["none", "none", "notice-turn", "land-send"] as const),
    background: r.chance(0.25),
    load: r.chance(0.2) ? 4 : 1,
    wide: r.chance(0.15),
  };
}

/** A message of `lines` lines (the person's multi-line send). */
export function linesOf(lines: number, seed: number): string {
  return Array.from(
    { length: lines },
    (_, index) => `line ${index + 1} of ${lines}: ${SENTENCES[(seed + index) % SENTENCES.length]}`,
  ).join("\n");
}

/** A sent prompt's images, as acpmux names them (hub/prompt_images.rs). */
const IMAGES = [
  { id: "img-fuzz-1", mimeType: "image/png", name: "screenshot.png", width: 1600, height: 1000 },
  { id: "img-fuzz-2", mimeType: "image/png", name: "trace.png", width: 800, height: 1200 },
];

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
  // The four splits every seed drew before `wide` (an axis of its own), so a seed keeps its size.
  const split = r.pick(["full", "half", "third", "quarter"] as const satisfies readonly Split[]);
  const history = r.int(1, 3);
  const axes = fuzzAxes(seed);
  return {
    seed,
    calls,
    chatter,
    subagents,
    steers,
    ending,
    recap,
    answer,
    viewport,
    scrollBy,
    split: axes.wide ? "wide" : split,
    history,
    axes,
  };
}

/** The seed's chat. */
export function fuzzScenario(seed: number, override: Partial<FuzzSpec> = {}): FuzzScenario {
  const spec = { ...fuzzSpec(seed), ...override };
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
  // hq#18554's axes, on their own stream (`r2`), so `r` draws every earlier choice as before.
  const { axes } = spec;
  const r2 = rng(seed ^ 0x68e31da4);
  const images = axes.send?.attach ? { images: IMAGES.slice(0, r2.int(1, 2)) } : {};
  const sent = axes.send ? linesOf(axes.send.lines, seed) : "";
  if (axes.background) b.background("bun run watch:fleet", { ms: r2.int(200, 2_500), after: r2.int(20, 300) });
  /// The person's multi-line steer, while the answer streams (or on the note's heels).
  const sendSteer = () => {
    if (axes.send?.at === "steer") b.steer(sent, { readMs: r2.int(50, 800), after: r2.int(10, 200), extra: images });
  };
  /// The turn's end: calls after the answer, a compaction, then acpmux's turn end.
  const endTurn = (after: number) => {
    for (let n = 0; n < axes.tailTools; n += 1)
      b.tool(`${r2.pick(COMMANDS)} # tail ${n + 1}`, { kind: r2.pick(KINDS), ms: r2.logInt(20, 900) }, r2.int(10, 300));
    if (axes.tail === "compaction") b.compaction({ ms: r2.int(150, 1_500), after: r2.int(10, 300) });
    b.turnEnd("completed", after);
  };
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
    sendSteer();
    if (spec.recap) recapCard();
    endTurn(r.int(16, 160));
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
      if (part === Math.floor(Math.ceil(words.length / per) / 2)) sendSteer();
    }
    if (spec.ending === "stream") {
      if (spec.recap) recapCard();
      endTurn(20);
    } else if (spec.ending === "recap") {
      recapCard();
      endTurn(r.int(100, 1_500));
    } else {
      if (spec.recap) recapCard();
      endTurn(r.int(400, 1_500));
    }
  }
  const built = b.build();
  const foldAt = lastIndex(built.steps, (step) => step.label === "turn_result");
  if (axes.background) b.backgroundEnds();
  // A queued message goes out the moment the turn ends; the person's next send a little later.
  if (axes.tail === "queued") b.prompt("queued: and then open the PR", r2.int(5, 60));
  if (axes.send?.at === "next") b.prompt(sent, r2.int(100, 900), images);
  if (axes.tail === "queued" || axes.send?.at === "next") {
    if (r2.chance(0.6)) b.say(text(r2, 1), { chunks: 2, chunkMs: 60, after: r2.int(50, 400) });
    b.turnEnd("completed", r2.int(100, 600));
  }
  if (axes.notice === "notice-turn") {
    // A notification starts a turn whose only activity is one or two calls.
    b.incoming("Background task finished: bun run watch:fleet (exit 0)", { kind: "notice" }, r2.int(100, 900));
    for (let n = r2.int(1, 2); n > 0; n -= 1)
      b.tool(`${r2.pick(COMMANDS)} # notice`, { kind: r2.pick(KINDS), ms: r2.logInt(20, 600) }, r2.int(20, 300));
    b.turnEnd("completed", r2.int(20, 400));
  } else if (axes.notice === "land-send") {
    // A land notice, and the agent passing it on: the "Sending message" row, then the turn's end.
    b.incoming(
      "Landed manaflow-ai/cmux#50101 at 1a2b3c4",
      { kind: "notice", title: "Landed #50101" },
      r2.int(100, 900),
    );
    b.tool("acpmux send coord 'Landed #50101.'", { kind: "execute", ms: r2.int(200, 1_500) }, r2.int(20, 300));
    b.turnEnd("completed", r2.int(20, 400));
  }
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

/// The stray-motion chat of a seed (scripts/fold-fuzz.ts `--sweep`; the judge is transcriptMotion.ts
/// `strayStarts`): the seed's turn, its end reached scrolled up on every odd seed, then the reader's sweep:
/// down to the bottom, up through the chat to its top a wheel's worth at a time, and down again. A quarter
/// of the seeds start the sweep while the fold still plays. Its own random stream, so the seed's turn is
/// the fuzz seed's. Leo, 2026-11-22: "your chat folds or whatever, i scroll down, some bullshit ABOVE
/// folds...? and plays an animation!? ... edge cases at teh top area of teh screeen and a long turn/tool
/// call/sterring situation that has a wide-ass aggressive fold".
export function strayScenario(seed: number): FuzzScenario & { sweepFrom: number } {
  const up = seed % 2 === 1 || fuzzSpec(seed).viewport === "up";
  const base = fuzzScenario(seed, up ? { viewport: "up" } : {});
  const r = rng(seed ^ 0x51ed270b);
  const steps = [...base.scenario.steps];
  let at = steps.at(-1)!.at;
  const reader = (action: ReaderAction, after: number) => {
    at += after;
    const label =
      "scroll" in action
        ? `reader scroll ${action.scroll}`
        : "open" in action
          ? `reader open ${action.open}`
          : `reader scrollBy ${action.scrollBy}`;
    steps.push({ type: "reader", at, label, reader: action });
  };
  const sweepFrom = steps.length;
  reader({ scrollBy: r.int(80, 240) }, r.chance(0.25) ? r.int(16, 200) : r.int(700, 1_500));
  for (let step = r.int(0, 2); step > 0; step -= 1) reader({ scrollBy: r.int(120, 400) }, r.int(40, 220));
  reader({ scroll: "bottom" }, r.int(40, 220));
  const ups = r.int(4, 12);
  for (let step = 0; step < ups; step += 1)
    reader({ scrollBy: -r.int(120, 480) }, r.chance(0.2) ? r.int(400, 900) : r.int(30, 180));
  reader({ scroll: "top" }, r.int(40, 400));
  for (let step = r.int(2, 6); step > 0; step -= 1) reader({ scrollBy: r.int(160, 520) }, r.int(30, 260));
  reader({ scroll: "bottom" }, r.int(200, 700));
  return { ...base, scenario: { ...base.scenario, steps }, sweepFrom };
}
