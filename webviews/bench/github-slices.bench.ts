// l10n-allow-file: benchmark output, not shipped UI.
// What one change to the GitHub page's snapshot costs React, on Chromium: a production build (React Compiler,
// minified, React's profiling build) of bench/github-slices/, the real GitHubPage over a stand-in store with a
// pull request of FILES files and ENTRIES conversation entries. Two events, each EVENTS times a round:
//   patch   one file's patch opens or closes (`patches` changes, as toggleFile and a streamed patch do);
//   write   the person's review goes sending, then idle (`write` changes, as submitReview does).
// Per event, the React commit time it caused (Profiler actualDuration, summed over its commits); a round's
// number is the median over its events, and the run prints the median and spread over ROUNDS fresh pages.
//   bun bench/github-slices.bench.ts [rounds=5] [files=120] [entries=200] [events=20]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import { reactWithCompiler } from "../reactCompiler.mjs";

const ROUNDS = Number(process.argv[2] ?? 5);
const FILES = Number(process.argv[3] ?? 120);
const ENTRIES = Number(process.argv[4] ?? 200);
const EVENTS = Number(process.argv[5] ?? 20);

const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "github-slices-bench-"));
const { build } = await import("vite");
await build({
  configFile: false,
  root: path.join(import.meta.dir, "github-slices"),
  base: "./",
  logLevel: "error",
  resolve: { alias: [{ find: /^react-dom\/client$/, replacement: "react-dom/profiling" }] },
  plugins: [...reactWithCompiler()],
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
const browser = await chromium.launch({ headless: true });
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0;

const rounds: { patch: number; write: number }[] = [];
for (let round = 0; round < ROUNDS; round++) {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${statics.port}/#files=${FILES}&entries=${ENTRIES}`);
  await page.waitForFunction(() => window.benchReady === true);
  const measure = (event: "patch" | "write") =>
    page.evaluate(
      async ({ event, count }) => {
        const settle = () => new Promise<void>((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0)));
        await settle();
        const costs: number[] = [];
        for (let i = 0; i < count; i++) {
          const from = window.benchCommits.length;
          if (event === "patch") window.benchPatch(i);
          else window.benchWrite(i % 2 === 0);
          await settle();
          costs.push(window.benchCommits.slice(from).reduce((sum, [, actual]) => sum + actual, 0));
        }
        return costs;
      },
      { event, count: EVENTS },
    );
  rounds.push({ patch: median(await measure("patch")), write: median(await measure("write")) });
  await page.close();
}
await browser.close();
void statics.stop();
fs.rmSync(out, { recursive: true, force: true });

for (const event of ["patch", "write"] as const) {
  const values = rounds.map((round) => round[event]);
  const sorted = [...values].sort((a, b) => a - b);
  console.log(
    `SLICES ${event} files=${FILES} entries=${ENTRIES}: p50 ${median(values).toFixed(3)} ms ` +
      `(min ${sorted[0]!.toFixed(3)}, max ${sorted.at(-1)!.toFixed(3)}) over ${ROUNDS} rounds: ${values.map((v) => v.toFixed(3)).join(" ")}`,
  );
}
