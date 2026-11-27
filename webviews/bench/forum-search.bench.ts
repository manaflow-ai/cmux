// l10n-allow-file: benchmark output, not shipped UI.
// What typing into the Forum page's search costs, on Chromium: a production build (React Compiler, minified,
// React's profiling build) of bench/forum-search/, the real ForumPage over THREADS threads. Each round types
// QUERY into the search field one character at a time, as a person does, and for each keystroke reads:
//   frame    from the input event to the next animation frame: how long the keystroke holds the field's
//            echo (the input-to-next-paint a person feels);
//   settled  from the input event until the list is drawn for that character and no commit is pending.
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

const rounds: { frame: number; settled: number; rows: number }[] = [];
for (let round = 0; round < ROUNDS; round++) {
  const page = await browser.newPage();
  await page.goto(`http://127.0.0.1:${statics.port}/#threads=${THREADS}`);
  await page.waitForFunction(() => window.benchReady === true);
  const result = await page.evaluate(async (query) => {
    const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
    const quiet = async () => {
      // Settled: two frames in a row with no new commit.
      let seen = -1;
      while (seen !== window.benchCommits.length) {
        seen = window.benchCommits.length;
        await frame();
        await frame();
      }
    };
    const input = document.querySelector<HTMLInputElement>("input.forum-search")!;
    const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    await quiet();
    const frames: number[] = [];
    const settled: number[] = [];
    for (let i = 1; i <= query.length; i++) {
      const start = performance.now();
      setValue.call(input, query.slice(0, i));
      input.dispatchEvent(new Event("input", { bubbles: true }));
      await frame();
      frames.push(performance.now() - start);
      await quiet();
      settled.push(performance.now() - start);
    }
    return { frames, settled, rows: document.querySelectorAll(".forum-thread-item").length };
  }, QUERY);
  rounds.push({ frame: median(result.frames), settled: median(result.settled), rows: result.rows });
  await page.close();
}
await browser.close();
statics.stop();
fs.rmSync(out, { recursive: true, force: true });

for (const key of ["frame", "settled"] as const) {
  const values = rounds.map((round) => round[key]);
  const sorted = [...values].sort((a, b) => a - b);
  console.log(
    `FORUM-SEARCH ${key} threads=${THREADS} query=${QUERY} rows=${rounds[0]?.rows}: p50 ${median(values).toFixed(1)} ms ` +
      `(min ${sorted[0]!.toFixed(1)}, max ${sorted.at(-1)!.toFixed(1)}) over ${ROUNDS} rounds: ${values.map((v) => v.toFixed(1)).join(" ")}`,
  );
}
