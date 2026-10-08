#!/usr/bin/env bun
// Turns a matrix run of experiment cases (webviews/scripts/gallery/manifest.ts --experiments) into
// what the compare view shows: one frame strip per arm (a row per script step, a column per time
// after the step's input) and the arm's frame timings, written as
//   <output>/strips/<entry>--<arm>.png
//   <output>/experiments.json    { "<entry id>": { "<arm>": ArmMeasurement } }  (format.ts)
//   <output>/experiments.html    the strips and the numbers on one page
// No browser: it reads the run's results.json and PNGs only.
//
//   bun experiments.ts --output-dir <run output> --run <run name> [--publish]
// --publish copies the run (with the strips) to :18796/matrix/<run>/ (runner.ts publishRun).
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { PNG } from "pngjs";

type StepStats = {
  durationMs: number;
  frames: number;
  p50: number;
  p95: number;
  max: number;
  over16: number;
  planMs: number;
  interactionMs?: number[];
};
type Result = {
  id: string;
  engine: "chromium" | "webkit";
  screenshot: string;
  params: Record<string, string | number | boolean>;
  experiment?: { experiment: string; arm: string; steps: { name: string; stats: StepStats; problems: string[] }[]; total: StepStats };
};
export type ArmMeasurement = {
  run: string;
  engine: "chromium" | "webkit";
  frames: number;
  p50: number;
  p95: number;
  max: number;
  over16: number;
  planMs?: number;
  settleCount?: number;
  settleP50?: number;
  settleP95?: number;
  settleMax?: number;
  strip?: string;
};

function settleStats(samples: readonly number[]) {
  if (!samples.length) return { settleCount: 0, settleP50: 0, settleP95: 0, settleMax: 0 };
  const sorted = [...samples].sort((a, b) => a - b);
  const at = (q: number) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))]!;
  const round = (value: number) => Math.round(value * 10) / 10;
  return {
    settleCount: sorted.length,
    settleP50: round(at(0.5)),
    settleP95: round(at(0.95)),
    settleMax: round(sorted[sorted.length - 1]!),
  };
}

/** Frames of one arm's strip: `freeze=<step>:<ms>` cases, by step then time. */
export function stripCells(results: Result[], entry: string, arm: string, engine: string) {
  const cells = results
    .filter((result) => result.engine === engine && result.params.entry === entry && result.params.arm === arm)
    .flatMap((result) => {
      const match = /^(\d+):(\d+)$/.exec(String(result.params.freeze ?? ""));
      return match ? [{ step: Number(match[1]), ms: Number(match[2]), file: result.screenshot }] : [];
    });
  const steps = [...new Set(cells.map((cell) => cell.step))].sort((a, b) => a - b);
  const times = [...new Set(cells.map((cell) => cell.ms))].sort((a, b) => a - b);
  return { steps, times, at: (step: number, ms: number) => cells.find((cell) => cell.step === step && cell.ms === ms)?.file };
}

/** Lays PNGs out in a grid (rows of equal-size frames, a 4 px gutter). */
function composeGrid(rows: (PNG | undefined)[][]): PNG {
  const sample = rows.flat().find(Boolean);
  if (!sample) return new PNG({ width: 1, height: 1 });
  const gutter = 8;
  const columns = Math.max(...rows.map((row) => row.length));
  const out = new PNG({ width: columns * (sample.width + gutter), height: rows.length * (sample.height + gutter) });
  out.data.fill(128);
  rows.forEach((row, y) =>
    row.forEach((png, x) => {
      if (png) PNG.bitblt(png, out, 0, 0, Math.min(png.width, sample.width), Math.min(png.height, sample.height), x * (sample.width + gutter), y * (sample.height + gutter));
    }),
  );
  return out;
}

export function buildExperimentReport(outputDir: string, run: string) {
  const results = JSON.parse(readFileSync(join(outputDir, "results.json"), "utf8")) as Result[];
  const measured = results.filter((result) => result.experiment);
  const report: Record<string, Record<string, ArmMeasurement>> = {};
  const sections: string[] = [];
  mkdirSync(join(outputDir, "strips"), { recursive: true });
  for (const result of measured) {
    const entry = String(result.params.entry);
    const arm = result.experiment!.arm;
    const { steps, times, at } = stripCells(results, entry, arm, result.engine);
    let strip: string | undefined;
    if (steps.length) {
      const rows = steps.map((step) =>
        times.map((ms) => {
          const file = at(step, ms);
          return file && existsSync(join(outputDir, file)) ? PNG.sync.read(readFileSync(join(outputDir, file))) : undefined;
        }),
      );
      strip = `strips/${entry}--${arm}-${result.engine}.png`;
      writeFileSync(join(outputDir, strip), PNG.sync.write(composeGrid(rows)));
    }
    const total = result.experiment!.total;
    const settled = result.experiment!.steps.flatMap((step) => step.stats.interactionMs ?? []);
    const settle = settleStats(settled);
    (report[entry] ??= {})[arm] = {
      run,
      engine: result.engine,
      frames: total.frames,
      p50: total.p50,
      p95: total.p95,
      max: total.max,
      over16: total.over16,
      planMs: total.planMs,
      ...settle,
      strip,
    };
    const stepRows = result.experiment!.steps
      .map((step) => {
        const stepSettle = settleStats(step.stats.interactionMs ?? []);
        return `<tr><td>${step.name}</td><td>${step.stats.durationMs}</td><td>${step.stats.frames}</td><td>${step.stats.p50}</td><td>${step.stats.p95}</td><td>${step.stats.max}</td><td>${step.stats.over16}</td><td>${step.stats.planMs}</td><td>${stepSettle.settleCount ? `${stepSettle.settleP50} / ${stepSettle.settleP95} / ${stepSettle.settleMax} (${stepSettle.settleCount})` : "—"}</td><td>${step.problems.join("; ")}</td></tr>`;
      })
      .join("");
    sections.push(
      `<section><h2>${entry} · arm ${arm} · ${result.engine}</h2><p>Action-to-settled p50 / p95 / max (count): ${settle.settleCount ? `${settle.settleP50} / ${settle.settleP95} / ${settle.settleMax} ms (${settle.settleCount})` : "no click, key or press-drag samples"}.</p><table><tr><th>step</th><th>ms</th><th>frames</th><th>p50</th><th>p95</th><th>max</th><th>&gt;16.7</th><th>plan ms</th><th>settle p50 / p95 / max (count)</th><th>problems</th></tr>${stepRows}</table>` +
        (strip ? `<p>Columns: ${times.join(", ")} ms after the input; rows: steps ${steps.join(", ")}.</p><img src="${strip}" style="max-width:100%">` : "") +
        `</section>`,
    );
  }
  writeFileSync(join(outputDir, "experiments.json"), `${JSON.stringify(report, null, 2)}\n`);
  writeFileSync(
    join(outputDir, "experiments.html"),
    `<!doctype html><meta charset="utf-8"><title>gallery experiments ${run}</title><style>body{font:13px system-ui;margin:24px}table{border-collapse:collapse;margin:8px 0}td,th{border:1px solid #ccc;padding:2px 8px;text-align:right}td:first-child,td:last-child{text-align:left}img{border:1px solid #ccc}</style><h1>Experiment run ${run}</h1>${sections.join("")}`,
  );
  return report;
}

if (import.meta.main) {
  const { values } = parseArgs({
    options: { "output-dir": { type: "string" }, run: { type: "string" }, publish: { type: "boolean", default: false } },
  });
  if (!values["output-dir"] || !values.run) throw new Error("--output-dir and --run are required");
  console.log(JSON.stringify(buildExperimentReport(values["output-dir"], values.run), null, 2));
  if (values.publish) {
    const { publishRun } = await import("./runner");
    console.error(`experiments: ${publishRun(values["output-dir"], values.run)}experiments.html`);
  }
}
