// l10n-allow-file: benchmark output, not shipped UI.
// What typing into the Forum page's search costs, on Chromium: a production build (React Compiler, minified,
// React's profiling build) of bench/forum-search/, the real ForumPage over THREADS threads. Each round types
// QUERY into the search field with real key presses, one character at a time, and for each keystroke reads:
//   inp      the keystroke's Event Timing duration (key down to the next paint, what INP reports; the API
//            records 16 ms and up, so a faster keystroke counts as 16);
//   settled  from the key press until the list shows that prefix's matches and two frames pass with no commit.
// A round's number is the median over its keystrokes; the run prints the median and spread over ROUNDS
// fresh pages.
//   bun bench/forum-search.bench.ts [rounds=5] [threads=2000] [query=sidebar]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import { reactWithCompiler } from "../reactCompiler.mjs";

const ROUNDS = Number(process.argv[2] ?? 5);
const THREADS = Number(process.argv[3] ?? 2000);
const QUERY = process.argv[4] ?? "sidebar";

const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "forum-search-bench-"));
const { build } = await import("vite");
await build({
  configFile: false,
  root: path.join(import.meta.dir, "forum-search"),
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

const rounds: { inp: number; settled: number; rows: number }[] = [];
for (let round = 0; round < ROUNDS; round++) {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${statics.port}/#threads=${THREADS}`);
  await page.waitForFunction(() => window.benchReady === true);
  const settle = (prefix: string) =>
    page.evaluate(async (prefix) => {
      const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
      const want = window.benchExpected(prefix);
      let seen = -1;
      while (seen !== window.benchCommits.length || document.querySelectorAll(".forum-thread-item").length !== want) {
        seen = window.benchCommits.length;
        await frame();
        await frame();
      }
    }, prefix);
  await page.focus("input.forum-search");
  await settle("");
  const inps: number[] = [];
  const settled: number[] = [];
  for (let i = 1; i <= QUERY.length; i++) {
    const from = await page.evaluate(() => window.benchEvents.length);
    const start = Date.now();
    await page.keyboard.press(QUERY[i - 1]!);
    await settle(QUERY.slice(0, i));
    settled.push(Date.now() - start);
    // Event Timing entries land after their paint; one more frame lets the observer deliver them.
    const durations = await page.evaluate(async (from) => {
      await new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 50)));
      return window.benchEvents
        .slice(from)
        .filter((entry) => entry.interactionId > 0)
        .map((entry) => entry.duration);
    }, from);
    inps.push(Math.max(16, ...durations));
  }
  const rows = await page.evaluate(() => document.querySelectorAll(".forum-thread-item").length);
  rounds.push({ inp: median(inps), settled: median(settled), rows });
  await page.close();
}
await browser.close();
void statics.stop();
fs.rmSync(out, { recursive: true, force: true });

for (const key of ["inp", "settled"] as const) {
  const values = rounds.map((round) => round[key]);
  const sorted = [...values].sort((a, b) => a - b);
  console.log(
    `FORUM-SEARCH ${key} threads=${THREADS} query=${QUERY} rows=${rounds[0]?.rows}: p50 ${median(values).toFixed(1)} ms ` +
      `(min ${sorted[0]!.toFixed(1)}, max ${sorted.at(-1)!.toFixed(1)}) over ${ROUNDS} rounds: ${values.map((v) => v.toFixed(1)).join(" ")}`,
  );
}
