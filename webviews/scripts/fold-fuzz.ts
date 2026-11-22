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
import type { Browser } from "playwright";
import { fuzzSpec, SPLITS, type FuzzSpec } from "../test/browser/fold-fuzz.scenario";
import { openRecorder, recordLook } from "./fold-variants-record";

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
};

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
    let most = 0;
    for (const row of samples[index]!.rows) {
      const was = prior.get(row[0]);
      if (!was || !seen(row) || !seen(was)) continue;
      most = Math.max(
        most,
        Math.abs(row[1] - was[1]),
        Math.abs(shownTop(row) - shownTop(was)),
        Math.abs(shownHeight(row) - shownHeight(was)),
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

  // (a) Grow: per row, the biggest bump (a rise, then a fall, by the smaller of the two).
  let grow = { key: "", px: 0, at: 0 };
  const heights = new Map<string, { h: number; index: number }[]>();
  for (let index = from; index < samples.length; index += 1)
    for (const row of samples[index]!.rows) {
      if (!seen(row)) continue;
      const list = heights.get(row[0]) ?? [];
      list.push({ h: shownHeight(row), index });
      heights.set(row[0], list);
    }
  for (const [key, list] of heights) {
    const lowAfter: number[] = new Array(list.length);
    for (let index = list.length - 1, low = Infinity; index >= 0; index -= 1)
      lowAfter[index] = low = Math.min(low, list[index]!.h);
    let lowBefore = Infinity;
    list.forEach(({ h, index }, at) => {
      lowBefore = Math.min(lowBefore, h);
      const bump = Math.min(h - lowBefore, h - lowAfter[at]!);
      if (bump > grow.px) grow = { key, px: bump, at: t(index) };
    });
  }
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

  // (c) The anchor. Scrolled up: the kept row under the view's center at the turn's end, by its top.
  // Following the end: the kept row nearest the view's bottom, by its bottom edge (follow pins the end).
  const before = samples[start]!;
  const last = samples.at(-1)!;
  const kept = new Map(last.rows.map((row) => [row[0], row]));
  const view = run.view || before.view;
  // The seed says whether the reader scrolled up; else the scroller's own end (less its dock padding).
  const following = spec
    ? spec.viewport === "bottom"
    : before.scrollTop + view >= before.scrollHeight - FOLLOW_SLACK_PX;
  const line = following ? view : view / 2;
  const anchor = before.rows
    .filter((row) => kept.has(row[0]) && !transient(row[0]) && seen(row))
    .map((row) => ({
      row,
      off:
        row[1] <= line && line <= row[1] + row[2]
          ? 0
          : Math.min(Math.abs(row[1] - line), Math.abs(row[1] + row[2] - line)),
    }))
    .sort((a, b) => a.off - b.off)[0]?.row;
  const landed = anchor && kept.get(anchor[0])!;
  const drift =
    !anchor || !landed ? 0 : following ? landed[1] + landed[2] - (anchor[1] + anchor[2]) : landed[1] - anchor[1];
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
    totalRisePx: round(totalRise),
    totalBumpPx: round(totalBump),
    personSpoke: prompted,
    anchorRow: anchor?.[0],
    anchorMode: following ? ("bottom" as const) : ("center" as const),
    anchorDriftPx: round(drift),
    overflowAnchor: run.overflowAnchor,
  };
}

type Ok = Exclude<FuzzNumbers, { error: string }>;
const ok = (n: FuzzNumbers | undefined): n is Ok => !!n && !("error" in n);

/** The seed's flags, given the anchor threshold. */
export function flagsOf(n: Ok, driftPx: number) {
  return {
    grow: n.growPx > GROW_PX || (n.totalBumpPx > GROW_PX && !n.personSpoke),
    // Phases of the fold's own: the ones the person's next message set off are counted apart.
    phases: n.phases.filter((phase) => !phase.person).length > 1,
    drift: Math.abs(n.anchorDriftPx) > driftPx,
  };
}

/** How bad a seed is, to rank the worst: each flag counts, then by how much. */
export function severity(n: Ok, driftPx: number) {
  const flags = flagsOf(n, driftPx);
  return (
    (flags.grow ? 1000 + Math.max(n.growPx, n.totalBumpPx) : 0) +
    (flags.phases ? 1000 + (n.phases.filter((phase) => !phase.person).length - 1) * 100 : 0) +
    (flags.drift ? 1000 + Math.abs(n.anchorDriftPx) : 0)
  );
}

/** The drift threshold from the data: the widest gap in log scale between sorted drifts above 1 px. */
export function driftThreshold(drifts: number[]) {
  const values = [...new Set(drifts.map((value) => Math.abs(value)).filter((value) => value >= 1))].sort(
    (a, b) => a - b,
  );
  let best = { gap: 0, at: 8 };
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

/** Plays one seed with one look in a fresh page, and returns its frames. */
async function playSeed(browser: Browser, port: number, look: string, seed: number): Promise<FuzzRun> {
  const { width, height } = SPLITS[fuzzSpec(seed).split];
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
  try {
    page.on("pageerror", (error) => console.error(`seed ${seed} ${look}: ${error.message}`));
    await page.goto(`http://127.0.0.1:${port}${PAGE}?width=${width}&height=${height}`, { timeout: 180_000 });
    await page.waitForFunction(() => "__fold" in window, undefined, { timeout: 120_000 });
    return (await page.evaluate(
      ([look, name]) =>
        (window as unknown as { __fold: { run(look: string, name: string): Promise<unknown> } }).__fold.run(look, name),
      [look, `fuzz:${seed}`] as const,
    )) as FuzzRun;
  } finally {
    await page.close();
  }
}

type Result = { seed: number; look: string; spec: FuzzSpec; numbers: FuzzNumbers; replayed?: boolean };

/** Every seed of every look, `jobs` pages at a time; a run with late frames plays again alone. */
async function fuzz(
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
  const one = async ({ look, seed }: { look: string; seed: number }, again = false) => {
    const file = keepSamples && path.join(keepSamples, `${look}-${seed}.samples.json`);
    // `--resume`: a run already on disk is read, not played (and the numbers come from today's analysis).
    if (file && resume && !again && existsSync(file))
      return analyze(JSON.parse(readFileSync(file, "utf8")), fuzzSpec(seed));
    const run = await playSeed(browser, port, look, seed).catch((error: unknown) => {
      console.error(`seed ${seed} ${look}: ${error instanceof Error ? error.message.split("\n")[0] : error}; again`);
      return playSeed(browser, port, look, seed);
    });
    if (file) writeFileSync(file, JSON.stringify(run));
    return analyze(run, fuzzSpec(seed));
  };
  let done = 0;
  const worker = async () => {
    for (let item = queue.shift(); item; item = queue.shift()) {
      const numbers = await one(item).catch((error: unknown) => ({ error: String(error) }) as FuzzNumbers);
      results.push({ ...item, spec: fuzzSpec(item.seed), numbers });
      done += 1;
      if (done % 25 === 0 || done === total) console.log(`${done}/${total}`);
    }
  };
  await Promise.all(Array.from({ length: jobs }, worker));
  // Late frames: the machine, not the fold. Play those again with nothing else running.
  const lateRuns = results.filter((result) => !ok(result.numbers) || result.numbers.lateFrames > 0.05);
  if (lateRuns.length) console.log(`${lateRuns.length} runs with late frames or errors: again, one at a time`);
  for (const result of lateRuns) {
    result.numbers = await one(result, true).catch((error: unknown) => ({ error: String(error) }) as FuzzNumbers);
    result.replayed = true;
  }
  return results.sort((a, b) => a.look.localeCompare(b.look) || a.seed - b.seed);
}

const describe = (spec: FuzzSpec) =>
  `${spec.calls} calls, ${spec.ending} end${spec.recap ? `, recap ${spec.recap}` : ""}${
    spec.steers.length ? `, steers ${spec.steers.join("+")}` : ""
  }${spec.subagents ? `, ${spec.subagents} subagent` : ""}${spec.chatter ? ", chatter" : ""}, ${spec.viewport}, ${spec.split}`;

/** The markdown: per look the flag counts, the drift spread, and the worst seeds. */
export function report(results: Result[], looks: string[], driftPx: number, worst = 10) {
  const lines = [
    `Seeds: ${new Set(results.map((r) => r.seed)).size}; drift threshold ${driftPx} px (from the data); ` +
      `scroll anchoring: overflow-anchor ${[...new Set(results.map((r) => (ok(r.numbers) ? r.numbers.overflowAnchor : "")))].filter(Boolean).join(", ")}.`,
    "",
    "| look | seeds | (a) grow | (b) >1 motion phase | (b) counting the person's next message | (c) drift, scrolled up | (c) drift, at the end | any flag | no motion at all | late-frame runs | errors |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
  ];
  for (const look of looks) {
    const mine = results.filter((r) => r.look === look);
    const good = mine.map((r) => r.numbers).filter(ok);
    const flags = good.map((n) => flagsOf(n, driftPx));
    const count = (pick: (f: ReturnType<typeof flagsOf>) => boolean) => flags.filter(pick).length;
    lines.push(
      `| ${look} | ${mine.length} | ${count((f) => f.grow)} | ${count((f) => f.phases)} | ${
        good.filter((n) => n.phases.length > 1).length
      } | ${good.filter((n, i) => flags[i]!.drift && n.anchorMode === "center").length} | ${
        good.filter((n, i) => flags[i]!.drift && n.anchorMode === "bottom").length
      } | ${count(
        (f) => f.grow || f.phases || f.drift,
      )} | ${good.filter((n) => n.phases.length === 0).length} | ${good.filter((n) => n.lateFrames > 0.05).length} | ${
        mine.length - good.length
      } |`,
    );
  }
  for (const look of looks) {
    const ranked = results
      .filter((r) => r.look === look && ok(r.numbers))
      .map((r) => ({ r, n: r.numbers as Ok, score: severity(r.numbers as Ok, driftPx) }))
      .filter((x) => x.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, worst);
    lines.push("", `### ${look}: the ${worst} worst seeds`, "");
    if (!ranked.length) {
      lines.push("None flagged.");
      continue;
    }
    lines.push(
      "| seed | scenario | grow px (row) | total grow-collapse px (rise before the fold) | phases (ms from turn end: set off by) | drift px |",
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
          .join("; ")} | ${n.anchorDriftPx} (${n.anchorMode}) |`,
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
  const drifts = results
    .map((r) => r.numbers)
    .filter(ok)
    .map((n) => n.anchorDriftPx);
  const driftPx = value("--drift") ? Number(value("--drift")) : driftThreshold(drifts);
  const table = report(results, looks, driftPx);
  const summary = Object.fromEntries(
    looks.map((look) => {
      const good = results
        .filter((r) => r.look === look)
        .map((r) => r.numbers)
        .filter(ok);
      const flags = good.map((n) => flagsOf(n, driftPx));
      return [
        look,
        {
          seeds: good.length,
          grow: flags.filter((f) => f.grow).length,
          phases: flags.filter((f) => f.phases).length,
          drift: flags.filter((f) => f.drift).length,
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
  console.log(table);
  if (gallery) {
    const before = value("--before") ?? looks[0]!;
    const after = value("--after") ?? looks.at(-1)!;
    const worst = results
      .filter((r) => r.look === before && ok(r.numbers))
      .sort((a, b) => severity(b.numbers as Ok, driftPx) - severity(a.numbers as Ok, driftPx))
      .slice(0, gallery);
    const dir = path.join(out, "gallery");
    mkdirSync(dir, { recursive: true });
    for (const r of worst) {
      const { width, height } = SPLITS[r.spec.split];
      const clips: string[] = [];
      for (const look of [before, after]) {
        const { clip } = await recordLook(recorder.browser, recorder.port, {
          look,
          scenario: `fuzz:${r.seed}`,
          width,
          height,
          out: dir,
          name: `seed-${r.seed}-${look}`,
          ffmpeg,
        });
        if (clip) clips.push(clip);
      }
      if (clips.length === 2) sideBySide(ffmpeg, clips, path.join(dir, `seed-${r.seed}-${before}-vs-${after}.mp4`));
      console.log(`gallery: seed ${r.seed} (${describe(r.spec)})`);
    }
  }
  await recorder.close();
}
