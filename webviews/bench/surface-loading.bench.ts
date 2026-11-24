// l10n-allow-file: benchmark output, not shipped UI.
// Time to content on every surface the app ships as a page, and any spinner or blank pane held past a bound (Leo,
// 2026-11-10: "Anything fucking slow, anything fucking bullshit, anything with a stupid ass fucking loading state.";
// 2026-11-11: "it's about the time to settled loading").
//
// The pages are built as the app ships them (scripts/cmux-next/build-pages-web.sh --out: one shared chunk graph, the
// production React, the packed `.deflate` files the app inflates on request) and served the way the app's scheme
// handler serves them. Each page opens cold (a new browser context) at `/<page>/?mock`, its in-memory provider standing
// in for the app; a page with no mock provider opens with no host at all, which is what it shows until the app answers.
// Every painted frame from navigation is read (test/support/paintedFrames.ts) and judged blank, loading (a spinner,
// skeleton, `aria-busy`, a progress bar or a "Loading…" line in view) or content (bench/surfaceLoadingFrames.ts).
// A page is read until its content has held QUIET_MS, or to WINDOW_MS.
//
//   time to content  when its settled content first painted: no blank or loading frame after it. A page still blank
//                    or loading at WINDOW_MS is held, and counts as WINDOW_MS.
//   over bound       its median time to content is past BOUND_MS (TARGET_MS.load), or it was held in any round.
//
// Rows (PERF_ROW, bench/perfRow.ts; the perf cron stores each as webui.<name>):
//   surface_loading.<page>.time_to_content   median and worst over rounds, ms, target BOUND_MS
//   surface_loading.worst_time_to_content    the slowest page's median, ms
//   surface_loading.over_bound               pages over the bound or held (count, target 0)
//   SURFACE_LOADING_JSON {...}               every round's metrics and the loaders each page showed
//
//   bun bench/surface-loading.bench.ts [rounds=3] [--pages settings,history] [--pages-dir DIR]
//   env: WINDOW_MS (4000), QUIET_MS (1000), BOUND_MS (1000)
/// <reference types="bun" />
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { inflateRawSync } from "node:zlib";
import { chromium } from "./browsers";
import { benchPositionals } from "./support/benchPage";
import { perfRow, TARGET_MS } from "./perfRow";
import { installPaintedFrames } from "../test/support/paintedFrames";
import {
  classifySurface,
  LOADER_SELECTOR,
  LOADING_TEXT,
  median,
  readSurfaceFrame,
  type SurfaceFrame,
  type SurfaceMetrics,
} from "./surfaceLoadingFrames";

const webviews = path.resolve(import.meta.dir, "..");
const repo = path.resolve(webviews, "..");
const ROUNDS = Number(benchPositionals()[0] ?? 3);
const WINDOW_MS = Number(process.env.WINDOW_MS ?? 4000);
const QUIET_MS = Number(process.env.QUIET_MS ?? 1000);
const BOUND_MS = Number(process.env.BOUND_MS ?? TARGET_MS.load);
const POLL_MS = 100;

const flag = (name: string) => {
  const at = process.argv.indexOf(name);
  return at >= 0 ? process.argv[at + 1] : undefined;
};

/// The app's pages, built as it ships them, into a directory of their own.
function buildPages(): { dir: string; cleanup: () => void } {
  const given = flag("--pages-dir");
  if (given) return { dir: path.resolve(given), cleanup: () => {} };
  const dir = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "surface-loading-"));
  const started = performance.now();
  const built = spawnSync("sh", [path.join(repo, "scripts/cmux-next/build-pages-web.sh"), "--out", dir], {
    cwd: repo,
    stdio: ["ignore", "ignore", "inherit"],
  });
  if (built.status !== 0) throw new Error(`build-pages-web.sh exited ${built.status}`);
  console.log(`built the pages in ${((performance.now() - started) / 1000).toFixed(1)} s`);
  return { dir, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

const MIME: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
  ".woff2": "font/woff2",
  ".png": "image/png",
};

/// Serves the built pages as the app's scheme handler does: `/<page>/` is its index.html, and a file kept packed
/// (`<name>.deflate`, scripts/pages/pack-pages.mjs) is inflated when its unpacked name is asked for.
function servePages(dir: string) {
  const root = path.resolve(dir);
  return Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(request) {
      let pathname = new URL(request.url).pathname;
      try {
        pathname = decodeURIComponent(pathname);
      } catch {
        // A malformed escape is read as itself.
      }
      if (pathname.endsWith("/")) pathname += "index.html";
      const file = path.resolve(root, `.${pathname}`);
      if (!file.startsWith(root + path.sep)) return new Response("not found", { status: 404 });
      const type = MIME[path.extname(file)] ?? "application/octet-stream";
      if (fs.existsSync(file) && fs.statSync(file).isFile())
        return new Response(Bun.file(file), { headers: { "content-type": type } });
      if (fs.existsSync(`${file}.deflate`))
        return new Response(inflateRawSync(fs.readFileSync(`${file}.deflate`)), { headers: { "content-type": type } });
      return new Response("not found", { status: 404 });
    },
  });
}

/// In the page from its first script on: every painted frame's state, kept in `window.__surfaceFrames`.
function recorderScript(): string {
  return `(() => {
    const read = (${readSurfaceFrame.toString()});
    const frames = (window.__surfaceFrames = []);
    const start = () => window.cmuxAfterPaint(() => {
      frames.push({ t: performance.now(), ...read(${JSON.stringify(LOADER_SELECTOR)}, ${JSON.stringify(LOADING_TEXT.source)}) });
    });
    if (typeof window.cmuxAfterPaint === "function") start();
    else addEventListener("DOMContentLoaded", start, { once: true });
  })();`;
}

type Round = SurfaceMetrics & { errors: string[]; mock: boolean };

async function measure(browser: Awaited<ReturnType<typeof chromium.launch>>, base: string, page: string, mock: boolean) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const tab = await context.newPage();
  const errors: string[] = [];
  tab.on("pageerror", (error) => errors.push(error.message.slice(0, 160)));
  await installPaintedFrames(tab);
  await tab.addInitScript(recorderScript());
  const startedAt = Date.now();
  await tab.goto(`${base}/${page}/${mock ? "?mock" : ""}`, { waitUntil: "commit" });
  let frames: SurfaceFrame[] = [];
  let now = 0;
  for (;;) {
    await Bun.sleep(POLL_MS);
    ({ frames, now } = await tab.evaluate(() => ({
      frames: ((window as unknown as { __surfaceFrames?: SurfaceFrame[] }).__surfaceFrames ?? []).slice(),
      now: performance.now(),
    })));
    if (now >= WINDOW_MS || Date.now() - startedAt > WINDOW_MS * 3) break;
    // Quiet: content since QUIET_MS ago with no frame of another state since.
    const lastOther = frames.findLast((frame) => frame.state !== "content");
    const firstContent = frames.find((frame) => frame.state === "content");
    if (firstContent && (lastOther ? now - lastOther.t : now - firstContent.t) >= QUIET_MS && frames.at(-1)?.state === "content")
      break;
  }
  await context.close();
  return { ...classifySurface(frames, now), errors, mock } satisfies Round;
}

/// Pages that boot their mock provider on `?mock` (src/pages/<page>/main.tsx reads it).
function hasMock(page: string): boolean {
  const main = path.join(webviews, "src/pages", page, "main.tsx");
  return fs.existsSync(main) && /["']mock["']/.test(fs.readFileSync(main, "utf8"));
}

const { dir, cleanup } = buildPages();
const only = flag("--pages")?.split(",").filter(Boolean);
const pages = fs
  .readdirSync(dir)
  .filter((name) => !name.startsWith("__") && fs.existsSync(path.join(dir, name, "index.html")))
  .filter((name) => !only || only.includes(name))
  .sort();
if (pages.length === 0) throw new Error(`no pages under ${dir}`);
const server = servePages(dir);
const base = `http://127.0.0.1:${server.port}`;
const browser = await chromium.launch({ headless: true });
const results: Record<string, Round[]> = {};
try {
  // Round-robin over the pages, so a slow minute of the runner lands on every page alike.
  for (let round = 0; round < ROUNDS; round += 1) {
    for (const page of pages) (results[page] ??= []).push(await measure(browser, base, page, hasMock(page)));
  }
} finally {
  await browser.close();
  await server.stop(true);
  cleanup();
}

type Summary = { page: string; medianMs: number; worstMs: number; held: number; over: boolean; loaders: string[] };
const summaries: Summary[] = pages.map((page) => {
  const rounds = results[page];
  const times = rounds.map((r) => r.timeToContentMs ?? WINDOW_MS);
  const medianMs = median(times) ?? WINDOW_MS;
  const held = rounds.filter((r) => r.held).length;
  const loaders = [...new Set(rounds.flatMap((r) => r.loaders.map((l) => l.name)))].slice(0, 4);
  return { page, medianMs, worstMs: Math.max(...times), held, over: medianMs > BOUND_MS || held > 0, loaders };
});
summaries.sort((a, b) => b.medianMs - a.medianMs);
console.log(`\nsurface loading: ${pages.length} pages, ${ROUNDS} rounds, bound ${BOUND_MS} ms, window ${WINDOW_MS} ms`);
console.log("page                  median ms  worst ms  held  loaders");
for (const s of summaries) {
  const mark = s.over ? " OVER" : "";
  console.log(
    `${s.page.padEnd(22)}${s.medianMs.toFixed(0).padStart(9)}${s.worstMs.toFixed(0).padStart(10)}${String(s.held).padStart(6)}  ${s.loaders.join(" ") || "-"}${mark}`,
  );
}
for (const s of summaries) {
  perfRow({
    name: `surface_loading.${s.page.replace(/-/g, "_")}.time_to_content`,
    p50: s.medianMs,
    p95: s.worstMs,
    target: BOUND_MS,
    samples: results[s.page].map((r) => r.timeToContentMs ?? WINDOW_MS),
  });
}
const worst = summaries[0];
perfRow({ name: "surface_loading.worst_time_to_content", p50: worst.medianMs, p95: worst.medianMs, target: BOUND_MS });
const over = summaries.filter((s) => s.over);
perfRow({ name: "surface_loading.over_bound", p50: over.length, p95: over.length, unit: "count", target: 0, floor: 0.5 });
console.log(
  "SURFACE_LOADING_JSON " +
    JSON.stringify({
      boundMs: BOUND_MS,
      windowMs: WINDOW_MS,
      rounds: ROUNDS,
      over: over.map((s) => s.page),
      pages: Object.fromEntries(summaries.map((s) => [s.page, { ...s, rounds: results[s.page] }])),
    }),
);
