#!/usr/bin/env bun
// The fold matrix: every look of the big Claude turn fold (turnEndFold.ts `TURN_END_LOOKS`) on a fixed base
// turn, changing one thing at a time, measured and recorded in headless Chrome at real speed.
// Leo, 2026-11-22: "these have conflating variables. ... what i meant was: lot of tool calls, lot of things
// potentially in between, maybe steers, maybe chatter from the model in between... and then it all collapses
// into Worked for. and the various situations in between that can come about too, those should be analyzed."
//
//   bun scripts/fold-matrix.ts [--looks fade,dissolve,...] [--cells base,steer,...] [--runs 3] [--out DIR] [--ffmpeg PATH]
//   (`none` in --looks is the control: the swap applied at once, no fold)
//
// The base turn (test/browser/fold-variants.harness.tsx `matrixTurn`): two earlier turns, then 30 calls,
// no chatter, no steer, no subagent, the reader at the bottom, a short answer, the turn ending 1.5 s after
// it, in a 720 x 640 pane. Each other cell changes one of those. Per cell and look it writes:
//   - maxJumpPx: the most a visible row moves between two frames;
//   - anchorDriftPx / anchorStepPx: where the row under the view's center ends against where it was, and the
//     most it moves in one frame (0 and 0: the reader's place holds);
//   - blink: the most a row drawn before and after the fold fades on the way (0: none);
//   - gashPx: the widest blank band past the one at rest; durationMs: the fold's first frame to its last change;
//   - a clip, and per cell one side-by-side clip of every look (cell-NAME.mp4).
// It writes DIR/matrix.json and DIR/matrix.md. Synthetic text only, so every clip can be public.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import type { MatrixCell } from "../test/browser/fold-variants.harness";
import { openRecorder, recordLook } from "./fold-variants-record";

const args = process.argv.slice(2);
const value = (name: string) => {
  const at = args.indexOf(name);
  return at >= 0 ? args[at + 1] : undefined;
};
const out = path.resolve(value("--out") ?? "/tmp/fold-matrix");
const ffmpeg = value("--ffmpeg") ?? "ffmpeg";
/** Runs per cell and look; each number is their median, and `runs` and `spread` (max jump's range) say how far apart they were. */
const repeats = Number(value("--runs") ?? 3);

const BASE: MatrixCell = {
  calls: 30,
  chatter: "none",
  steer: false,
  subagent: false,
  viewport: "bottom",
  timing: "after",
  answer: "short",
};

type Cell = { id: string; varies: string; cell: MatrixCell; width: number; height: number };
const cell = (id: string, varies: string, change: Partial<MatrixCell>, width = 720, height = 640): Cell => ({
  id,
  varies,
  cell: { ...BASE, ...change },
  width,
  height,
});

/** The base, then one change each. */
export const CELLS: Cell[] = [
  cell("base", "base: 30 calls, bottom, full pane", {}),
  cell("calls-5", "5 calls", { calls: 5 }),
  cell("calls-120", "120 calls", { calls: 120 }),
  cell("chatter", "the model's chatter between calls", { chatter: "between" }),
  cell("steer", "a steer mid-turn", { steer: true }),
  cell("subagent", "a subagent inside", { subagent: true }),
  cell("scrolled-up", "the reader scrolled up", { viewport: "up" }),
  cell("streaming", "the turn ends while the answer streams", { timing: "during" }),
  cell("long-answer", "a long closing answer fills the view", { answer: "recap" }),
  cell("recap-card", "the wrap-up recap card comes in under the answer", { wrapUp: "short" }),
  cell("recap-long", "a long recap card", { wrapUp: "long" }),
  cell("recap-up", "the recap card, the reader scrolled up", { wrapUp: "short", viewport: "up" }),
  cell("recap-long-up", "a long recap card, the reader scrolled up", { wrapUp: "long", viewport: "up" }),
  cell("ends-on-tool", "the turn ends right after its last call, no answer", { ending: "tool" }),
  cell("last-output", "the last call prints 12 lines just before the answer", { ending: "output" }),
  cell("split-half", "half split (360 x 640)", {}, 360, 640),
  cell("split-third", "third split (240 x 640)", {}, 240, 640),
  cell("split-quarter", "quarter split (360 x 320)", {}, 360, 320),
];

type Numbers = NonNullable<Awaited<ReturnType<typeof recordLook>>["numbers"]>;

/** One side-by-side clip of every look's clip for a cell, five across, each held on its last frame. */
function sideBySide(clips: string[], target: string, width: number, height: number) {
  const scale = width >= 720 ? 0.4 : width >= 360 ? 0.6 : 0.8;
  const w = Math.round((width * scale) / 2) * 2;
  const h = Math.round((height * scale) / 2) * 2;
  const across = Math.min(5, clips.length);
  const inputs = clips.flatMap((clip) => ["-i", clip]);
  const scaled = clips
    .map((_, i) => `[${i}:v]scale=${w}:-2,pad=${w}:${h}:0:0:black,tpad=stop_mode=clone:stop_duration=3[v${i}]`)
    .join(";");
  const layout = clips.map((_, i) => `${(i % across) * w}_${Math.floor(i / across) * h}`).join("|");
  const stack =
    clips.length === 1
      ? `${scaled};[v0]null[out]`
      : `${scaled};${clips.map((_, i) => `[v${i}]`).join("")}xstack=inputs=${clips.length}:layout=${layout}:fill=black[out]`;
  const made = spawnSync(
    ffmpeg,
    [
      "-y",
      "-loglevel",
      "error",
      ...inputs,
      "-filter_complex",
      stack,
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
  const { TURN_END_LOOKS } = await import("../src/agent-session/acpmux/conversation/turnEndFold");
  // `--recaps a,b`: the columns are recap entrances (turnEndFold.ts TURN_END_RECAPS), on the first look.
  const recaps = value("--recaps")?.split(",");
  const lookList = value("--looks")?.split(",") ?? [...TURN_END_LOOKS];
  const looks = recaps ?? lookList;
  const only = value("--cells")?.split(",");
  const cells = only ? CELLS.filter((c) => only.includes(c.id)) : CELLS;
  mkdirSync(out, { recursive: true });
  const recorder = await openRecorder();
  const results: Record<string, Record<string, Numbers | { error: string }>> = {};
  for (const c of cells) {
    results[c.id] = {};
    const clips: string[] = [];
    for (const look of looks) {
      const runs: Numbers[] = [];
      let kept: string | undefined;
      for (let attempt = 0; attempt < repeats; attempt += 1) {
        const options = {
          ...(recaps ? { look: lookList[0]!, recap: look } : { look }),
          scenario: `matrix:${encodeURIComponent(JSON.stringify(c.cell))}`,
          width: c.width,
          height: c.height,
          out,
          name: `${c.id}-${look}${attempt ? `-${attempt + 1}` : ""}`,
          ffmpeg,
        };
        // One more try on a page that never loaded (the dev server busy), so one miss does not end the run.
        const { numbers, clip } = await recordLook(recorder.browser, recorder.port, options).catch((error) => {
          console.error(`${c.id}-${look}: ${error instanceof Error ? error.message.split("\n")[0] : error}; again`);
          return recordLook(recorder.browser, recorder.port, options).catch(() => ({
            numbers: undefined,
            clip: undefined,
          }));
        });
        if (numbers) runs.push(numbers);
        if (clip && !kept) kept = clip;
        console.log(`${c.id.padEnd(14)} ${look.padEnd(10)} ${attempt + 1} ${JSON.stringify(numbers)}`);
      }
      results[c.id]![look] = runs.length ? median(runs) : { error: "no fold played" };
      if (kept) clips.push(kept);
    }
    if (clips.length) sideBySide(clips, path.join(out, `cell-${c.id}.mp4`), c.width, c.height);
    writeFileSync(path.join(out, "matrix.json"), JSON.stringify({ cells, looks, results }, null, 1));
  }
  await recorder.close();
  writeFileSync(path.join(out, "matrix.md"), table(cells, looks, results));
  console.log(path.join(out, "matrix.md"));
}

/** Each numeric field's median over the runs, with the max jump's spread. */
function median(runs: Numbers[]): Numbers & { runs: number; spread: number } {
  const mid = (values: number[]) => {
    const sorted = [...values].sort((a, b) => a - b);
    const half = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[half]! : (sorted[half - 1]! + sorted[half]!) / 2;
  };
  const out: Record<string, unknown> = { ...runs[0] };
  for (const key of Object.keys(runs[0]!)) {
    const values = runs.map((run) => (run as Record<string, unknown>)[key]).filter((v) => typeof v === "number");
    if (values.length === runs.length) out[key] = Math.round(mid(values as number[]) * 10) / 10;
  }
  const jumps = runs.map((run) => run.maxJumpPx);
  return {
    ...(out as Numbers),
    runs: runs.length,
    spread: Math.round((Math.max(...jumps) - Math.min(...jumps)) * 10) / 10,
  };
}

/** The markdown: per metric a cells x looks table. */
export function table(cells: Cell[], looks: string[], results: Record<string, Record<string, unknown>>) {
  const metric = (title: string, read: (n: Numbers) => string) =>
    [
      `### ${title}`,
      "",
      `| cell | ${looks.join(" | ")} |`,
      `|---|${looks.map(() => "---").join("|")}|`,
      ...cells.map(
        (c) =>
          `| ${c.varies} | ${looks
            .map((look) => {
              const n = results[c.id]?.[look] as Numbers | { error: string } | undefined;
              return !n || "error" in n ? "-" : read(n);
            })
            .join(" | ")} |`,
      ),
      "",
    ].join("\n");
  return [
    metric("Max jump per frame (px, visible rows; median of the runs, ± its spread)", (n) => {
      const spread = (n as { spread?: number }).spread;
      return spread ? `${n.maxJumpPx} ±${spread}` : `${n.maxJumpPx}`;
    }),
    metric("Reader's anchor: drift / most in one frame (px)", (n) => `${n.anchorDriftPx} / ${n.anchorStepPx}`),
    metric("Blink (how far a kept row fades, 0 to 1)", (n) => `${n.blink}`),
    metric(
      "Pixels: the worst frame's share of all the change (an instant swap is near 1)",
      (n) => `${(n as { worstFrameShare?: number }).worstFrameShare ?? "-"}`,
    ),
    metric("Recap card's live arrival: the rows around it, biggest step / the card's own (px)", (n) => {
      const arrival = (n as { recapArrival?: { neighbourStepPx: number; cardStepPx: number } }).recapArrival;
      return arrival ? `${arrival.neighbourStepPx} / ${arrival.cardStepPx}` : "-";
    }),
    metric(
      "False grow: the turn's calls taller than at its end, before they fold / the answer's own growth (px)",
      (n) => {
        const grow = (n as { turnGrow?: { blockPx: number; answerPx: number } }).turnGrow;
        return grow ? `${grow.blockPx} / ${grow.answerPx}` : "-";
      },
    ),
    metric("Duration (ms)", (n) => `${n.durationMs}`),
    metric("Gap (px past the gap at rest)", (n) => `${n.gashPx}`),
  ].join("\n");
}
