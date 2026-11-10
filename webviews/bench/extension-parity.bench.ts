// l10n-allow-file: benchmark output, not shipped UI.
// Extension parity (Leo, 2026-11-10: "you can add your own stuff just as performant if not more than us"):
// the same content drawn by an app (scene ops into SceneRenderer, the path a New Tab widget or a Session
// Info app section takes) and by the first-party React component, on Chromium, from a production build
// (React Compiler, minified, React's profiling build) of bench/extension-parity/. Two cases, each with a
// fresh page per round:
//   clock  the example clock app's tick (one Text node's `update` op) vs the first-party New Tab clock
//          (NewTabExtras `clock`, its `now` a minute later);
//   list   one row of a 30-row pull request list: an app's Row subtitle vs Session Info's first-party
//          Changes section (one pull request's live title).
// Per update, over UPDATES updates a round, as medians over the rounds:
//   main_ms   the update's main-thread work: the synchronous update (flushSync: the store or state change,
//             React's render and commit) and the style and layout it forces (p50/p95);
//   commits   React commits under the arm's Profiler per update.
// Rows: extension_parity.<case>.<scene|react>.main_ms (ms p50/p95) and .commits (count).
//   bun bench/extension-parity.bench.ts [rounds=3] [updates=200]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { reactWithCompiler } from "../reactCompiler.mjs";
import { perfRow, TARGET_MS } from "./perfRow";

const ROUNDS = Number(process.argv[2] ?? 3);
const UPDATES = Number(process.argv[3] ?? 200);
if (!Number.isInteger(ROUNDS) || ROUNDS < 1 || !Number.isInteger(UPDATES) || UPDATES < 10)
  throw new Error("usage: extension-parity.bench.ts [rounds>=1] [updates>=10]");
const CASES = ["clock", "list"] as const;
const ARMS = ["scene", "react"] as const;
type Case = (typeof CASES)[number];
type Arm = (typeof ARMS)[number];

const webviews = path.resolve(import.meta.dir, "..");
const sharedStyles = path.join(webviews, "src/agent-session/shared/styles.css");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "extension-parity-bench-"));
const { build } = await import("vite");
await build({
  configFile: false,
  root: path.join(import.meta.dir, "extension-parity"),
  base: "./",
  logLevel: "error",
  // The profiling build of react-dom: production React whose Profiler reports commits.
  resolve: { alias: [{ find: /^react-dom\/client$/, replacement: "react-dom/profiling" }] },
  plugins: [
    {
      name: "bench-shared-styles",
      enforce: "pre",
      transform(code: string, id: string) {
        if (id.split("?")[0] !== sharedStyles) return null;
        return { code: code.replace(/^@import .*$/gm, ""), map: null };
      },
    },
    ...reactWithCompiler(),
  ],
  build: { outDir: out, emptyOutDir: true },
});
const statics = Bun.serve({
  port: 0,
  hostname: "127.0.0.1",
  async fetch(request) {
    const pathname = new URL(request.url).pathname;
    const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
    return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
  },
});
const browser = await chromium.launch({
  ...(process.env.CMUX_CHROME_HEADLESS_SHELL
    ? { executablePath: process.env.CMUX_CHROME_HEADLESS_SHELL }
    : { channel: "chrome" }),
  headless: true,
});

const pct = (values: number[], p: number) =>
  values.length ? [...values].sort((a, b) => a - b)[Math.max(0, Math.ceil(values.length * p) - 1)]! : 0;
const median = (values: number[]) => pct(values, 0.5);

type Round = { p50: number; p95: number; commits: number; rows: number };

async function round(benchCase: Case, arm: Arm): Promise<Round> {
  const context = await browser.newContext({ viewport: { width: 800, height: 900 } });
  const page = await context.newPage();
  await page.goto(`http://127.0.0.1:${statics.port}/#case=${benchCase}&arm=${arm}`);
  await page.waitForFunction(() => window.benchReady === true);
  // Both list arms draw all 30 rows before the first update (Changes opens past its five).
  if (benchCase === "list")
    await page.waitForFunction(
      () => document.querySelectorAll(".cmux-app-scene-row, .acpmux-session-info-pr").length >= 30,
    );
  await page.waitForTimeout(200);
  const result = await page.evaluate(
    ({ updates }) =>
      new Promise<{ ms: number[]; commits: number; rows: number }>((resolve) => {
        const ms: number[] = [];
        const from = window.benchCommits.length;
        let index = 0;
        // One update a frame, as a tick or a pushed status arrives: never two in one task.
        const step = () => {
          index += 1;
          const started = performance.now();
          window.benchUpdate(index);
          ms.push(performance.now() - started);
          if (index < updates) requestAnimationFrame(step);
          else
            resolve({
              ms: ms.slice(5), // the first few warm the JIT
              commits: (window.benchCommits.length - from) / updates,
              rows: document.querySelectorAll(".cmux-app-scene-row, .acpmux-session-info-pr").length,
            });
        };
        requestAnimationFrame(step);
      }),
    { updates: UPDATES },
  );
  await context.close();
  return { p50: pct(result.ms, 0.5), p95: pct(result.ms, 0.95), commits: result.commits, rows: result.rows };
}

const table: string[] = ["| case | path | p50 ms | p95 ms | commits/update |", "| --- | --- | --- | --- | --- |"];
try {
  for (const benchCase of CASES) {
    for (const arm of ARMS) {
      const rounds: Round[] = [];
      for (let index = 0; index < ROUNDS; index++) rounds.push(await round(benchCase, arm));
      const of = (pick: (r: Round) => number) => median(rounds.map(pick));
      const label = arm === "scene" ? "extension (scene ops)" : "first-party React";
      console.log(
        `extension-parity ${benchCase} ${arm} rounds=${ROUNDS} updates=${UPDATES} ` +
          `mainMs=${of((r) => r.p50).toFixed(3)}/${of((r) => r.p95).toFixed(3)} ` +
          `commits=${of((r) => r.commits).toFixed(2)} rows=${of((r) => r.rows)}`,
      );
      table.push(
        `| ${benchCase} | ${label} | ${of((r) => r.p50).toFixed(3)} | ${of((r) => r.p95).toFixed(3)} | ${of((r) => r.commits).toFixed(2)} |`,
      );
      const name = `extension_parity.${benchCase}.${arm}`;
      perfRow({
        name: `${name}.main_ms`,
        p50: of((r) => r.p50),
        p95: of((r) => r.p95),
        target: TARGET_MS.frameWork,
        floor: 0.2,
      });
      perfRow({
        name: `${name}.commits`,
        p50: of((r) => r.commits),
        p95: of((r) => r.commits),
        unit: "count",
        floor: 0.5,
        clock: "cpu",
      });
    }
  }
  console.log(table.join("\n"));
} finally {
  await browser.close();
  await statics.stop(true);
  fs.rmSync(out, { recursive: true, force: true });
}
