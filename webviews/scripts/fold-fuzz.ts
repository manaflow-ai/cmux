#!/usr/bin/env bun
// The fold fuzzer: hundreds of seeded Claude turns (test/browser/fold-fuzz.scenario.ts), each ending in the big
// fold (turnEndFold.ts), played at real speed in headless Chrome through the fold recorder's page
// (test/browser/fold-variants.harness.tsx) and read every frame (60 fps).
// Leo, 2026-11-22: "oh i think there's some sort of like... false grow then collapse with the tool calls on the
// end of turn folding you have. well, when things get long, it just generally gets quite awkward. you need to
// simulate tons of situations exemplified by various situations and steers coming in at various times and tool
// calls at various times and turn ends at various".
//
//   bun scripts/fold-fuzz.ts [--seeds 500] [--from 1] [--look fade[,snapshot,...]] [--jobs 6] [--out DIR]
//     [--gallery 10 --before fade --after snapshot] [--ffmpeg PATH] [--only 12,40,...] [--resume] [--drift PX]
//     [--baseline test/transcript-motion-baseline.json]
//
// Every seed, from its turn's `turn_end` to the last frame, is flagged for:
//   (a) grow: a row's (or block's) drawn height rises and then falls, or the transcript's whole height rises
//       between the turn's end and the fold's first frame (with no prompt or steer landing then);
//   (b) phases: content moves, stops for at least 2 frames, then moves again (each later phase names the
//       records that landed just before it);
//   (c) drift: the kept row under the view's center at the turn's end lands more than the threshold from where
//       it was. The threshold comes from the data: the widest gap (in log scale) in every run's sorted drift
//       above 1 px, unless `--drift PX` sets it. The pane's scroll-anchoring arm is reported (`overflow-anchor`
//       on the scroller: `none` means the transcript's own bottom-follow and anchor, scrollAnchor.ts, alone).
// A run whose frames came late (more than 5% over 2 frame lengths) is played again alone, so a stall of the
// machine is not read as a stop. The `none` look is the control: the swap applied at once, no fold.
// It writes DIR/fuzz.json (every seed's spec and numbers) and DIR/fuzz.md (the table, the worst seeds), and
// with `--gallery N` records the N worst seeds of `--before` and `--after` as clips side by side.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { Browser, Page } from "playwright";
import { fuzzSpec, SPLITS, type FuzzSpec } from "../test/browser/fold-fuzz.scenario";
import { openRecorder, recordLook } from "./fold-variants-record";
import {
  countFlags,
  stepClass,
  transcriptMoves,
  type MotionFlag,
  type MotionRecord,
} from "../test/support/transcriptMotion";

const PAGE = "/test/browser/fold-variants.html";

type Row = [key: string, top: number, height: number, ink: number, shownTop?: number, shownHeight?: number];
type Sample = { t: number; folding: boolean; view: number; scrollHeight: number; scrollTop: number; rows: Row[] };
export type FuzzRun = {
  look: string;
  samples: Sample[];
  marks: { step: number; t: number; label: string }[];
  view: number;
  overflowAnchor: string;
  foldAt: number;
  /** The transcript motion detector's frames (test/support/transcriptMotion.ts). */
  motion?: MotionRecord;
};

/** The detector's verdict on one run: counts by kind, by the step each came after, and the first few. */
export function motionVerdict(record: MotionRecord | undefined) {
  if (!record) return undefined;
  const flags = transcriptMoves(record);
  const byStep: Record<string, number> = {};
  for (const flag of flags) byStep[stepClass(flag)] = (byStep[stepClass(flag)] ?? 0) + 1;
  // The worst first: the biggest jump of each element, then by size.
  const worst = new Map<string, MotionFlag>();
  for (const flag of flags) {
    const id = `${flag.kind}:${flag.key}`;
    if ((worst.get(id)?.px ?? -1) < flag.px) worst.set(id, flag);
  }
  // The stray starts by what started (docs/design/transcript-animation-rules.md), with one stack each.
  const strays: Record<string, { n: number; stack?: string }> = {};
  for (const flag of flags) {
    if (flag.kind !== "offscreen-start" && flag.kind !== "scroll-start") continue;
    const [what = "", stack] = (flag.detail ?? "").split(" @ ");
    const id = `${flag.kind} ${what.replace(/ at -?[\d.]+\.\.-?[\d.]+ of [\d.]+/, "")}`;
    strays[id] = { n: (strays[id]?.n ?? 0) + 1, stack: strays[id]?.stack ?? stack };
  }
  return {
    ...countFlags(flags),
    frames: record.frames.length,
    starts: record.starts?.length ?? 0,
    strays,
    byStep,
    first: [...worst.values()]
      .filter((flag) => flag.kind !== "offscreen-start" && flag.kind !== "scroll-start")
      .sort((a, b) => b.px - a.px)
      .slice(0, 6),
  };
}
export type MotionVerdict = NonNullable<ReturnType<typeof motionVerdict>>;

/** Below this a move or a height change is layout rounding, not motion (px). */
const STILL_PX = 0.5;
/** A height that rises and falls by more than this, or a transcript that grows by it, is a grow (px). */
const GROW_PX = 1;
/** A row drawn with at least this ink is visible. */
const SEEN_INK = 0.05;
/** Still frames that end a motion phase. */
const STOP_FRAMES = 2;
/** A view this near its end at the turn's end is following it (scrollAnchor.ts's deadband). */
const FOLLOW_SLACK_PX = 4;

const seen = (row: Row) => row[3] > SEEN_INK;
const shownTop = (row: Row) => row[4] ?? row[1];
const shownHeight = (row: Row) => row[5] ?? row[2];
/** The band of a row the reader sees: what its clip shows (the sampler reads a clipped row's inside the
 *  view), else its box, cut to the view (`view`, its height): a clip coming off a row past the view's edge,
 *  or a row growing past it, moves nothing on screen. */
const seenBand = (row: Row, view: number) => {
  const top = Math.min(view, Math.max(0, shownTop(row)));
  return { top, height: Math.min(view, Math.max(0, shownTop(row) + shownHeight(row))) - top };
};
const round = (value: number) => Math.round(value * 10) / 10;
/** Fold copies and replace snapshots are drawn for the fold only; they are never an anchor. */
const transient = (key: string) => key.startsWith("ghost-") || key.startsWith("snap:") || key === "fold-card";

export type FuzzNumbers = ReturnType<typeof analyze>;

/** One seed's numbers, from its turn's end to its last frame. */
export function analyze(run: FuzzRun, spec?: Pick<FuzzSpec, "viewport">) {
  const { samples, marks } = run;
  const end = marks.find((mark) => mark.step === run.foldAt);
  const turnEnd = [...marks].reverse().find((mark) => mark.step <= run.foldAt && mark.label === "turn_end") ?? end;
  if (!end || !turnEnd) return { error: "the turn's end was not sampled" as const };
  const from = samples.findIndex((sample) => sample.t >= turnEnd.t);
  if (from < 0) return { error: "no frame after the turn's end" as const };
  const start = Math.max(0, from - 1);
  const foldIndex = samples.findIndex((sample, index) => index >= from && sample.folding);
  // Frame pacing over the window: a stalled machine draws late frames, which would read as stops.
  const gaps = samples.slice(from + 1).map((sample, index) => sample.t - samples[from + index]!.t);
  const frame = median(gaps) || 1000 / 60;
  const late = gaps.filter((gap) => gap > frame * 2).length / Math.max(1, gaps.length);

  // (b) Motion per frame: the most any row seen on both frames moved or changed its drawn height.
  const moved: number[] = [];
  for (let index = from; index < samples.length; index += 1) {
    const prior = new Map(samples[index - 1]?.rows.map((row) => [row[0], row]) ?? []);
    const view = samples[index]!.view;
    let most = 0;
    for (const row of samples[index]!.rows) {
      const was = prior.get(row[0]);
      if (!was || !seen(row) || !seen(was)) continue;
      const band = seenBand(row, view);
      const before = seenBand(was, samples[index - 1]!.view);
      most = Math.max(
        most,
        Math.abs(row[1] - was[1]),
        Math.abs(band.top - before.top),
        Math.abs(band.height - before.height),
      );
    }
    moved.push(most);
  }
  const phases: { from: number; to: number; frames: number; px: number; after: string[] }[] = [];
  let still = Infinity;
  moved.forEach((px, offset) => {
    const index = from + offset;
    if (px <= STILL_PX) {
      still += 1;
      return;
    }
    const current = phases.at(-1);
    if (current && still < STOP_FRAMES) {
      current.to = index;
      current.frames += still + 1;
      current.px = Math.max(current.px, px);
    } else {
      // What landed in the frames just before it: the record or reader step that set it off.
      const since = samples[Math.max(0, index - STOP_FRAMES - 1)]!.t;
      const after = marks.filter((mark) => mark.t > since && mark.t <= samples[index]!.t).map((mark) => mark.label);
      phases.push({ from: index, to: index, frames: 1, px, after });
    }
    still = 0;
  });
  const t = (index: number) => Math.round(samples[index]!.t - turnEnd.t);

  // (a) Grow: per row, the biggest bump (a rise, then a fall, by the smaller of the two) of its laid-out
  // height; and apart, of the height a fold's clip shows of it (a crop that closes and opens again).
  const bumpOf = (height: (row: Row) => number) => {
    let worst = { key: "", px: 0, at: 0 };
    const heights = new Map<string, { h: number; index: number }[]>();
    for (let index = from; index < samples.length; index += 1)
      for (const row of samples[index]!.rows) {
        if (!seen(row)) continue;
        const list = heights.get(row[0]) ?? [];
        list.push({ h: height(row), index });
        heights.set(row[0], list);
      }
    for (const [key, list] of heights) {
      const lowAfter: number[] = Array.from({ length: list.length }, () => 0);
      for (let index = list.length - 1, low = Infinity; index >= 0; index -= 1)
        lowAfter[index] = low = Math.min(low, list[index]!.h);
      let lowBefore = Infinity;
      list.forEach(({ h, index }, at) => {
        lowBefore = Math.min(lowBefore, h);
        const bump = Math.min(h - lowBefore, h - lowAfter[at]!);
        if (bump > worst.px) worst = { key, px: bump, at: t(index) };
      });
    }
    return worst;
  };
  const grow = bumpOf((row) => row[2]);
  const clip = bumpOf(shownHeight);
  // The transcript's whole height, from the turn's end to the fold's first frame (or the last frame).
  const until = foldIndex >= 0 ? foldIndex : samples.length - 1;
  let totalRise = 0;
  for (let index = from; index < until; index += 1)
    totalRise = Math.max(totalRise, samples[index]!.scrollHeight - samples[start]!.scrollHeight);
  // The false grow then collapse of the whole: the transcript taller than at the turn's end, then shorter
  // than that peak by the end (the smaller of the rise and the fall).
  let peak = samples[start]!.scrollHeight;
  let totalBump = 0;
  for (let index = from; index < samples.length; index += 1) {
    peak = Math.max(peak, samples[index]!.scrollHeight);
    totalBump = Math.max(totalBump, Math.min(peak - samples[start]!.scrollHeight, peak - samples[index]!.scrollHeight));
  }
  const prompted = marks.some(
    (mark) => mark.t >= turnEnd.t && (mark.label.startsWith("prompt:") || mark.label.startsWith("steer")),
  );

  // (c) The anchor: the kept row under the view's center at the turn's end (a folded row is not one; the
  // nearest kept row is), and how far its top lands from where it was. Following the end, the same for the
  // kept row nearest the view's bottom, by its bottom edge (what follow holds), reported beside it.
  const before = samples[start]!;
  const last = samples.at(-1)!;
  const kept = new Map(last.rows.map((row) => [row[0], row]));
  const view = run.view || before.view;
  // The seed says whether the reader scrolled up; else the scroller's own end.
  const following = spec
    ? spec.viewport === "bottom"
    : before.scrollTop + view >= before.scrollHeight - FOLLOW_SLACK_PX;
  const nearest = (line: number) =>
    before.rows
      .filter((row) => kept.has(row[0]) && !transient(row[0]) && seen(row))
      .map((row) => ({
        row,
        off:
          row[1] <= line && line <= row[1] + row[2]
            ? 0
            : Math.min(Math.abs(row[1] - line), Math.abs(row[1] + row[2] - line)),
      }))
      .sort((a, b) => a.off - b.off)[0]?.row;
  const anchor = nearest(view / 2);
  const drift = anchor ? kept.get(anchor[0])![1] - anchor[1] : 0;
  const endRow = following ? nearest(view) : undefined;
  const endDrift = endRow ? kept.get(endRow[0])![1] + kept.get(endRow[0])![2] - (endRow[1] + endRow[2]) : undefined;
  // A phase the person set off: one that starts after their next message landed (a mid-fold steer).
  const personAt = marks.find(
    (mark) => mark.t >= turnEnd.t && (mark.label.startsWith("prompt:") || mark.label.startsWith("steer")),
  )?.t;

  return {
    folded: foldIndex >= 0,
    frames: samples.length - from,
    frameMs: round(frame),
    lateFrames: Math.round(late * 100) / 100,
    phases: phases.map((phase) => ({
      fromMs: t(phase.from),
      toMs: t(phase.to),
      frames: phase.frames,
      maxPx: round(phase.px),
      after: phase.after,
      person: personAt !== undefined && samples[phase.from]!.t >= personAt,
    })),
    growPx: round(grow.px),
    growRow: grow.key,
    growAtMs: grow.at,
    clipWobblePx: round(clip.px),
    clipWobbleRow: clip.key,
    totalRisePx: round(totalRise),
    totalBumpPx: round(totalBump),
    personSpoke: prompted,
    anchorRow: anchor?.[0],
    anchorMode: following ? ("bottom" as const) : ("center" as const),
    anchorDriftPx: round(drift),
    endDriftPx: endDrift === undefined ? undefined : round(endDrift),
    overflowAnchor: run.overflowAnchor,
    motion: motionVerdict(run.motion),
  };
}

type Ok = Exclude<FuzzNumbers, { error: string }>;
const ok = (n: FuzzNumbers | undefined): n is Ok => !!n && !("error" in n);

/**
 * The seed's flags, given the anchor threshold. With the control's drift for the seed (`none`: the same turn,
 * no fold), (c) is the drift the fold adds; the turn's end moves rows by itself (its view reorders and
 * collapses), and that is not the fold's.
 */
export function flagsOf(n: Ok, driftPx: number, control?: number) {
  return {
    grow: n.growPx > GROW_PX || (n.totalBumpPx > GROW_PX && !n.personSpoke),
    // Phases of the fold's own: the ones the person's next message set off are counted apart.
    phases: n.phases.filter((phase) => !phase.person).length > 1,
    drift: Math.abs(n.anchorDriftPx - (control ?? 0)) > driftPx,
    /** The detector: an untouched element moved or resized more than 1 px in a frame. */
    jump: !!n.motion && n.motion.move + n.motion.resize > 0,
    /** The detector: an animated move off the house easing or past its ceiling. */
    offCurve: !!n.motion && n.motion["off-curve"] > 0,
  };
}

/** How bad a seed is, to rank the worst: each flag counts, then by how much. */
export function severity(n: Ok, driftPx: number, control?: number) {
  const flags = flagsOf(n, driftPx, control);
  return (
    (flags.grow ? 1000 + Math.max(n.growPx, n.totalBumpPx) : 0) +
    (flags.phases ? 1000 + (n.phases.filter((phase) => !phase.person).length - 1) * 100 : 0) +
    (flags.drift ? 1000 + Math.abs(n.anchorDriftPx - (control ?? 0)) : 0)
  );
}

/**
 * The drift threshold from the data: the widest gap, in log scale, between two neighbouring drifts (each
 * seed's |drift|, 0.5 px and up, every look), up to a quarter of the shortest pane (`cap`). Drift is mostly
 * 0 or several lines; the gap between the two is where layout rounding ends and a move begins. Never under 2.
 */
export function driftThreshold(drifts: number[], cap = SPLITS.quarter.height / 4) {
  const values = [
    ...new Set(drifts.map((value) => Math.abs(value)).filter((value) => value >= 0.5 && value <= cap)),
  ].sort((a, b) => a - b);
  let best = { gap: 0, at: 2 };
  for (let index = 1; index < values.length; index += 1) {
    const gap = Math.log(values[index]!) - Math.log(values[index - 1]!);
    if (gap > best.gap) best = { gap, at: Math.sqrt(values[index]! * values[index - 1]!) };
  }
  return round(Math.max(2, best.at));
}

function median(values: number[]) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)]!;
}

/** Each page's DevTools session, to slow its CPU for the `load` axis. */
const cdpOf = new WeakMap<Page, Promise<import("playwright").CDPSession>>();

type FoldWindow = { __fold: { run(look: string, name: string): Promise<unknown>; size(w: number, h: number): void } };

/** A page of the recorder's harness, kept for many seeds: loading it is the slow part, not playing one. */
async function openPage(browser: Browser, port: number) {
  const page = await browser.newPage({ viewport: SPLITS.full, deviceScaleFactor: 1 });
  page.on("pageerror", (error) => console.error(`page: ${error.message}`));
  await page.goto(`http://127.0.0.1:${port}${PAGE}`, { timeout: 60_000 });
  await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 60_000 });
  return page;
}

/** `--sweep`: play each seed's stray-motion chat (fold-fuzz.scenario.ts `strayScenario`): its end reached
 *  scrolled up on odd seeds, then the reader's sweep down and up through the top. */
export const fuzzMode = { sweep: false };

/** Plays one seed with one look on `page` at the seed's split size, and returns its frames. */
async function playSeed(page: Page, look: string, seed: number): Promise<FuzzRun> {
  const spec = fuzzSpec(seed);
  const { width, height } = SPLITS[spec.split];
  await page.setViewportSize({ width, height });
  // The `load` axis: the page's CPU slowed (1: as fast as the runner).
  if (!cdpOf.has(page)) cdpOf.set(page, page.context().newCDPSession(page));
  await (await cdpOf.get(page)!).send("Emulation.setCPUThrottlingRate", { rate: spec.axes.load });
  return (await page.evaluate(
    ([look, name, width, height]) => {
      const fold = (window as unknown as FoldWindow).__fold;
      fold.size(width, height);
      return fold.run(look, name);
    },
    [look, `${fuzzMode.sweep ? "stray" : "fuzz"}:${seed}`, width, height] as const,
  )) as FuzzRun;
}

/** One seed with one look; `control` is the same seed's drift with no fold, when `none` ran too. */
export type Result = {
  seed: number;
  look: string;
  spec: FuzzSpec;
  numbers: FuzzNumbers;
  replayed?: boolean;
  control?: number;
};

/** Every seed of every look, `jobs` pages at a time; a run with late frames plays again alone. */
export async function fuzz(
  browser: Browser,
  port: number,
  looks: string[],
  seeds: number[],
  jobs: number,
  keepSamples?: string,
  resume = false,
) {
  const results: Result[] = [];
  const queue = looks.flatMap((look) => seeds.map((seed) => ({ look, seed })));
  const total = queue.length;
  /** A worker's page, opened on its first seed and opened again after a failure. */
  type Slot = { page?: Page };
  const pageOf = async (slot: Slot) =>
    (slot.page ??= await openPage(browser, port).catch(() => openPage(browser, port)));
  const one = async ({ look, seed }: { look: string; seed: number }, slot: Slot, again = false) => {
    const file = keepSamples && path.join(keepSamples, `${look}-${seed}.samples.json`);
    // `--resume`: a run already on disk is read, not played (and the numbers come from today's analysis).
    if (file && resume && !again && existsSync(file))
      return analyze(JSON.parse(readFileSync(file, "utf8")), fuzzSpec(seed));
    const run = await playSeed(await pageOf(slot), look, seed).catch(async (error: unknown) => {
      console.error(
        `seed ${seed} ${look}: ${error instanceof Error ? error.message.split("\n")[0] : String(error)}; again`,
      );
      // A fresh page: the old one may be the trouble.
      await slot.page?.close().catch(() => {});
      slot.page = undefined;
      return playSeed(await pageOf(slot), look, seed);
    });
    if (file) writeFileSync(file, JSON.stringify(run));
    return analyze(run, fuzzSpec(seed));
  };
  const slots: Slot[] = Array.from({ length: jobs }, () => ({}));
  let done = 0;
  const worker = async (slot: Slot) => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      const numbers = await one(item, slot).catch((error: unknown) => ({ error: String(error) }) as FuzzNumbers);
      results.push({ ...item, spec: fuzzSpec(item.seed), numbers });
      done += 1;
      if (done % 25 === 0 || done === total) console.log(`${done}/${total}`);
    }
  };
  await Promise.all(slots.map(worker));
  // Late frames: the machine, not the fold. Play those again with nothing else running.
  // A seed on the `load` axis is slowed on purpose: its late frames are the case, not the machine.
  const lateRuns = results.filter(
    (result) => !ok(result.numbers) || (result.numbers.lateFrames > 0.05 && result.spec.axes.load === 1),
  );
  if (lateRuns.length) console.log(`${lateRuns.length} runs with late frames or errors: again, one at a time`);
  for (const result of lateRuns) {
    result.numbers = await one(result, slots[0]!, true).catch(
      (error: unknown) => ({ error: String(error) }) as FuzzNumbers,
    );
    result.replayed = true;
  }
  await Promise.all(slots.map((slot) => slot.page?.close().catch(() => {})));
  return results.sort((a, b) => a.look.localeCompare(b.look) || a.seed - b.seed);
}

const describe = (spec: FuzzSpec) => {
  const { axes } = spec;
  const extra = [
    axes.send && `send ${axes.send.lines} lines${axes.send.attach ? " + images" : ""} (${axes.send.at})`,
    axes.tailTools && `${axes.tailTools} tail calls`,
    axes.tail !== "plain" && axes.tail,
    axes.notice !== "none" && axes.notice,
    axes.background && "background",
    axes.load > 1 && `load x${axes.load}`,
  ].filter(Boolean);
  return `${spec.calls} calls, ${spec.ending} end${spec.recap ? `, recap ${spec.recap}` : ""}${
    spec.steers.length ? `, steers ${spec.steers.join("+")}` : ""
  }${spec.subagents ? `, ${spec.subagents} subagent` : ""}${spec.chatter ? ", chatter" : ""}, ${spec.viewport}, ${spec.split}${
    extra.length ? `, ${extra.join(", ")}` : ""
  }`;
};

/** The steps a detector flag is counted under, in the table's order. */
const STEP_CLASSES = [
  "turn-end",
  "stream",
  "tool",
  "steer",
  "send",
  "notice",
  "compaction",
  "subagent",
  "scroll",
  "other",
  "no step",
] as const;

/** The detector's table: per look, the seeds it flags and its flags by kind and by the step before them. */
export function detectorTable(results: Result[], looks: string[]) {
  const lines = [
    "### The motion detector (test/support/transcriptMotion.ts): every element, every frame",
    "",
    "A `move` or `resize` is an element no step touched and no animation moves, drawn more than 1 px from its last frame; `off-curve` is a geometry animation off the house easing or past 240 ms.",
    "",
    `| look | seeds | seeds with a jump (move or resize) | seeds off-curve | move flags | resize flags | off-curve animations | ${STEP_CLASSES.map((name) => `after ${name}`).join(" | ")} |`,
    `|---|---|---|---|---|---|---|${STEP_CLASSES.map(() => "---").join("|")}|`,
  ];
  for (const look of looks) {
    const verdicts = results
      .filter((r) => r.look === look && ok(r.numbers))
      .map((r) => (r.numbers as Ok).motion)
      .filter((v): v is MotionVerdict => !!v);
    const sum = (pick: (v: MotionVerdict) => number) => verdicts.reduce((total, v) => total + pick(v), 0);
    lines.push(
      `| ${look} | ${verdicts.length} | ${verdicts.filter((v) => v.move + v.resize > 0).length} | ${
        verdicts.filter((v) => v["off-curve"] > 0).length
      } | ${sum((v) => v.move)} | ${sum((v) => v.resize)} | ${sum((v) => v["off-curve"])} | ${STEP_CLASSES.map((name) =>
        sum((v) => v.byStep[name] ?? 0),
      ).join(" | ")} |`,
    );
  }
  lines.push("", ...strayTable(results, looks));
  return lines;
}

/** The stray-motion table: per look, every animation start that broke the rule, grouped by what started. */
export function strayTable(results: Result[], looks: string[]) {
  const lines = [
    "### Stray animation starts (docs/design/transcript-animation-rules.md)",
    "",
    "`offscreen-start`: an animation started on a row outside the view. `scroll-start`: one started while the reader scrolled, on a row he gave no input to and whose data was not new.",
    "",
    "| look | seeds | starts seen | seeds with a stray | offscreen-start | scroll-start |",
    "|---|---|---|---|---|---|",
  ];
  const groups = new Map<string, { n: number; seeds: Set<number>; stack?: string }>();
  for (const look of looks) {
    const runs = results.filter((r) => r.look === look && ok(r.numbers) && (r.numbers as Ok).motion);
    const verdicts = runs.map((r) => (r.numbers as Ok).motion!);
    const sum = (pick: (v: MotionVerdict) => number) => verdicts.reduce((total, v) => total + pick(v), 0);
    lines.push(
      `| ${look} | ${verdicts.length} | ${sum((v) => v.starts)} | ${
        verdicts.filter((v) => v["offscreen-start"] + v["scroll-start"] > 0).length
      } | ${sum((v) => v["offscreen-start"])} | ${sum((v) => v["scroll-start"])} |`,
    );
    for (const r of runs)
      for (const [id, { n, stack }] of Object.entries((r.numbers as Ok).motion!.strays ?? {})) {
        const group = groups.get(`${look} ${id}`) ?? { n: 0, seeds: new Set<number>(), stack };
        group.n += n;
        group.seeds.add(r.seed);
        groups.set(`${look} ${id}`, group);
      }
  }
  if (groups.size) {
    lines.push(
      "",
      "| look, rule and what started | starts | seeds | e.g. seeds | where (stack) |",
      "|---|---|---|---|---|",
    );
    for (const [id, group] of [...groups].sort((a, b) => b[1].n - a[1].n).slice(0, 30))
      lines.push(
        `| ${id.replace(/\|/g, "/")} | ${group.n} | ${group.seeds.size} | ${[...group.seeds].slice(0, 5).join(", ")} | ${(group.stack ?? "").replace(/\|/g, "/").slice(0, 220)} |`,
      );
  }
  return lines;
}

/** The kinds the CI ratchet holds: the three motion faults and the two stray starts
 *  (docs/design/transcript-animation-rules.md, "The detector"). All five come from `countFlags`, so a
 *  kind left out here is a kind the gate cannot see at all, whatever the baseline lists. */
export const RATCHET_KINDS = ["move", "resize", "off-curve", "offscreen-start", "scroll-start"] as const;
export type RatchetCounts = Record<(typeof RATCHET_KINDS)[number], number>;

/** Each seed's detector counts for one look: what the CI ratchet (transcript-motion-baseline.json) holds. */
export function seedFlags(results: Result[], look: string) {
  const flags: Record<string, RatchetCounts> = {};
  for (const r of results) {
    if (r.look !== look || !ok(r.numbers) || !(r.numbers as Ok).motion) continue;
    const v = (r.numbers as Ok).motion!;
    const counts = Object.fromEntries(RATCHET_KINDS.map((kind) => [kind, v[kind] ?? 0])) as RatchetCounts;
    if (RATCHET_KINDS.some((kind) => counts[kind] > 0)) flags[r.seed] = counts;
  }
  return flags;
}

/** The markdown: per look the flag counts, the drift spread, and the worst seeds. */
export function report(results: Result[], looks: string[], driftPx: number, worst = 10) {
  const lines = [
    `Seeds: ${new Set(results.map((r) => r.seed)).size}; drift threshold ${driftPx} px (from the data); ` +
      `scroll anchoring: overflow-anchor ${[...new Set(results.map((r) => (ok(r.numbers) ? r.numbers.overflowAnchor : "")))].filter(Boolean).join(", ")}.`,
    "",
    "| look | seeds | (a) grow | (a) clip wobble, not layout | (b) >1 motion phase | (b) counting the person's next message | (c) drift, scrolled up | (c) drift, at the end | (c) drift the fold adds (vs `none`) | any flag | a flag the control lacks | no motion at all | late-frame runs | errors |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
  ];
  // The control's flags per seed: what the same turn shows with no fold.
  const controlFlags = new Map(
    results.filter((r) => r.look === "none" && ok(r.numbers)).map((r) => [r.seed, flagsOf(r.numbers as Ok, driftPx)]),
  );
  for (const look of looks) {
    const mine = results.filter((r) => r.look === look);
    const kept = mine.filter((r) => ok(r.numbers));
    const good = kept.map((r) => r.numbers as Ok);
    const flags = kept.map((r) => flagsOf(r.numbers as Ok, driftPx, r.control));
    const count = (pick: (f: ReturnType<typeof flagsOf>) => boolean) => flags.filter(pick).length;
    const raw = good.map((n) => Math.abs(n.anchorDriftPx) > driftPx);
    const controlled = kept.some((r) => r.control !== undefined);
    const fresh = kept.filter((r, i) => {
      const mine = flags[i]!;
      const theirs = controlFlags.get(r.seed);
      return theirs && ((mine.grow && !theirs.grow) || (mine.phases && !theirs.phases) || mine.drift);
    }).length;
    lines.push(
      `| ${look} | ${mine.length} | ${count((f) => f.grow)} | ${good.filter((n) => n.clipWobblePx > GROW_PX && n.growPx <= GROW_PX).length} | ${count((f) => f.phases)} | ${
        good.filter((n) => n.phases.length > 1).length
      } | ${good.filter((n, i) => raw[i] && n.anchorMode === "center").length} | ${
        good.filter((n, i) => raw[i] && n.anchorMode === "bottom").length
      } | ${controlled ? count((f) => f.drift) : "no control"} | ${count(
        (f) => f.grow || f.phases || f.drift,
      )} | ${controlFlags.size ? fresh : "no control"} | ${good.filter((n) => n.phases.length === 0).length} | ${good.filter((n) => n.lateFrames > 0.05).length} | ${
        mine.length - good.length
      } |`,
    );
  }
  lines.push("", ...detectorTable(results, looks));
  for (const look of looks) {
    const ranked = results
      .filter((r) => r.look === look && ok(r.numbers))
      .map((r) => ({ r, n: r.numbers as Ok, score: severity(r.numbers as Ok, driftPx, r.control) }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, worst);
    lines.push("", `### ${look}: the ${worst} worst seeds`, "");
    if (!ranked.length) {
      lines.push("None flagged.");
      continue;
    }
    lines.push(
      "| seed | scenario | grow px (row) | total grow-collapse px (rise before the fold) | phases (ms from turn end: set off by) | drift px (anchor; the control's) |",
      "|---|---|---|---|---|---|",
    );
    for (const { r, n } of ranked)
      lines.push(
        `| ${r.seed} | ${describe(r.spec)} | ${n.growPx}${n.growPx > GROW_PX ? ` (${n.growRow} at ${n.growAtMs} ms)` : ""} | ${n.totalBumpPx} (${n.totalRisePx}${
          n.personSpoke ? ", prompted" : ""
        }) | ${n.phases
          .map(
            (p) =>
              `${p.person ? "(person) " : ""}${p.fromMs}-${p.toMs}${p.after.length ? `: ${p.after.join(", ").slice(0, 60)}` : ""}`,
          )
          .join(
            "; ",
          )} | ${n.anchorDriftPx} (${n.anchorMode}${r.control === undefined ? "" : `; no fold ${r.control}`}) |`,
      );
  }
  return lines.join("\n");
}

/** Before and after clips of one seed, side by side, each held on its last frame. */
function sideBySide(ffmpeg: string, clips: string[], target: string) {
  const inputs = clips.flatMap((clip) => ["-i", clip]);
  const filter =
    clips.map((_, i) => `[${i}:v]scale=-2:360,tpad=stop_mode=clone:stop_duration=4[v${i}]`).join(";") +
    `;${clips.map((_, i) => `[v${i}]`).join("")}hstack=inputs=${clips.length}[out]`;
  const made = spawnSync(
    ffmpeg,
    [
      "-y",
      "-loglevel",
      "error",
      ...inputs,
      "-filter_complex",
      filter,
      "-map",
      "[out]",
      "-t",
      "4",
      "-r",
      "60",
      "-c:v",
      "libx264",
      "-crf",
      "22",
      "-pix_fmt",
      "yuv420p",
      "-movflags",
      "+faststart",
      target,
    ],
    { stdio: "inherit" },
  );
  return made.status === 0;
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const value = (name: string) => {
    const at = args.indexOf(name);
    return at >= 0 ? args[at + 1] : undefined;
  };
  fuzzMode.sweep = args.includes("--sweep");
  const count = Number(value("--seeds") ?? 500);
  const first = Number(value("--from") ?? 1);
  const seeds = value("--only")?.split(",").map(Number) ?? Array.from({ length: count }, (_, i) => first + i);
  const looks = (value("--look") ?? value("--looks") ?? "fade").split(",");
  const jobs = Number(value("--jobs") ?? 6);
  const out = path.resolve(value("--out") ?? "/tmp/fold-fuzz");
  const ffmpeg = value("--ffmpeg") ?? "ffmpeg";
  const gallery = Number(value("--gallery") ?? 0);
  mkdirSync(out, { recursive: true });
  const recorder = await openRecorder();
  const started = performance.now();
  // Every run's frames are kept (DIR/samples/LOOK-SEED.samples.json), to read a seed by hand and to
  // `--resume`: a run on disk is analyzed again, not played again.
  const keep = path.join(out, "samples");
  mkdirSync(keep, { recursive: true });
  const results = await fuzz(recorder.browser, recorder.port, looks, seeds, jobs, keep, args.includes("--resume"));
  // The control: what the turn's end alone does to each seed's anchor.
  const control = new Map(
    results.filter((r) => r.look === "none" && ok(r.numbers)).map((r) => [r.seed, (r.numbers as Ok).anchorDriftPx]),
  );
  for (const r of results) r.control = control.get(r.seed);
  const drifts = results
    .map((r) => r.numbers)
    .filter(ok)
    .map((n) => n.anchorDriftPx);
  const driftPx = value("--drift") ? Number(value("--drift")) : driftThreshold(drifts);
  const table = report(results, looks, driftPx);
  const summary = Object.fromEntries(
    looks.map((look) => {
      const good = results.filter((r) => r.look === look && ok(r.numbers));
      const flags = good.map((r) => flagsOf(r.numbers as Ok, driftPx, r.control));
      return [
        look,
        {
          seeds: good.length,
          grow: flags.filter((f) => f.grow).length,
          phases: flags.filter((f) => f.phases).length,
          drift: flags.filter((f) => f.drift).length,
          jump: flags.filter((f) => f.jump).length,
          offCurve: flags.filter((f) => f.offCurve).length,
        },
      ];
    }),
  );
  writeFileSync(
    path.join(out, "fuzz.json"),
    JSON.stringify(
      {
        looks,
        seeds: seeds.length,
        driftPx,
        summary,
        wallS: Math.round((performance.now() - started) / 1000),
        results,
      },
      null,
      1,
    ),
  );
  writeFileSync(path.join(out, "fuzz.md"), table);
  // Per look, each flagged seed's detector counts (the CI ratchet's shape).
  writeFileSync(
    path.join(out, "flags.json"),
    JSON.stringify(Object.fromEntries(looks.map((look) => [look, seedFlags(results, look)])), null, 1),
  );
  // `--baseline PATH`: the CI ratchet (test/transcript-motion-fuzz-browser.test.ts) for the first look.
  const baselinePath = value("--baseline");
  if (baselinePath)
    writeFileSync(
      baselinePath,
      `${JSON.stringify({ look: looks[0], seeds: seeds.length, flagged: seedFlags(results, looks[0]!) }, null, 1)}\n`,
    );
  console.log(table);
  if (gallery) {
    const before = value("--before") ?? looks[0]!;
    const after = value("--after") ?? looks.at(-1)!;
    // Ranked on `--rank` (the after look by default: what ships), worst first, a seed whose flags the control
    // (`none`, no fold) shares counting below one the fold alone sets off.
    const rank = value("--rank") ?? after;
    const controlRun = new Map(
      results.filter((r) => r.look === "none" && ok(r.numbers)).map((r) => [r.seed, r.numbers as Ok]),
    );
    const own = (r: Result) => {
      const theirs = controlRun.get(r.seed);
      const mine = flagsOf(r.numbers as Ok, driftPx, r.control);
      const base = theirs && flagsOf(theirs, driftPx);
      return !base || (mine.grow && !base.grow) || (mine.phases && !base.phases) || mine.drift ? 1 : 0;
    };
    const worst = results
      .filter((r) => r.look === rank && ok(r.numbers))
      .map((r) => ({ r, score: own(r) * 10_000 + severity(r.numbers as Ok, driftPx, r.control) }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, gallery)
      .map((x) => x.r);
    const dir = path.join(out, "gallery");
    mkdirSync(dir, { recursive: true });
    for (const r of worst) {
      const { width, height } = SPLITS[r.spec.split];
      const target = path.join(dir, `seed-${r.seed}-${before}-vs-${after}.mp4`);
      if (args.includes("--resume") && existsSync(target)) continue;
      const clips: string[] = [];
      for (const look of [before, after]) {
        const record = () =>
          recordLook(recorder.browser, recorder.port, {
            look,
            scenario: `fuzz:${r.seed}`,
            width,
            height,
            out: dir,
            name: `seed-${r.seed}-${look}`,
            ffmpeg,
          });
        // A fresh page sometimes never loads on a busy machine: once more, then the seed goes without a clip.
        const made = await record()
          .catch(record)
          .catch((error: unknown) => {
            console.error(
              `gallery: seed ${r.seed} ${look}: ${error instanceof Error ? error.message.split("\n")[0] : String(error)}`,
            );
            return undefined;
          });
        if (made?.clip) clips.push(made.clip);
      }
      if (clips.length === 2) sideBySide(ffmpeg, clips, target);
      console.log(`gallery: seed ${r.seed} (${describe(r.spec)})`);
    }
  }
  await recorder.close();
}
