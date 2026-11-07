// Opening the new chat's Projects picker (FolderPopover) with many projects, on Chromium: a
// production build (React Compiler, minified) of bench/project-picker/, the popover alone with N
// synthetic folders and a stand-in host that answers each badge's `project.icon`. Each round is a
// fresh page; per N it records, as medians over the rounds:
//   open      the trigger's press to the first frame painted after it (the press's Event Timing
//             duration: input to next paint, which Chromium rounds to 8 ms);
//   reopen    the same for the second open of that page (closed with Escape in between);
//   filter    one typed letter in the search field to the next paint (the worst of three);
//   settle    long-task time in the second after the first open (badge answers re-rendering rows);
//   rows      rows in the DOM when open; asks: `project.icon` asks the open made.
//   bun bench/project-picker-open.bench.ts [rounds=5] [counts=100,1000,5000]
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";
import { reactWithCompiler } from "../reactCompiler.mjs";

const ROUNDS = Number(process.argv[2] ?? 5);
const COUNTS = (process.argv[3] ?? "100,1000,5000").split(",").map(Number);
const webviews = path.resolve(import.meta.dir, "..");
const sharedStyles = path.join(webviews, "src/agent-session/shared/styles.css");

const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "project-picker-bench-"));
const { build } = await import("vite");
await build({
  configFile: false,
  root: path.join(import.meta.dir, "project-picker"),
  base: "./",
  logLevel: "error",
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

const median = (values: number[]) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] ?? 0;
};

type Round = { open: number; reopen: number; filter: number; settle: number; rows: number; asks: number };

async function round(count: number): Promise<Round> {
  const context = await browser.newContext({ viewport: { width: 1200, height: 800 } });
  const page = await context.newPage();
  await page.addInitScript(() => {
    const w = window as unknown as { benchEvents: { name: string; duration: number }[]; benchLong: number[][] };
    w.benchEvents = [];
    w.benchLong = [];
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) w.benchEvents.push({ name: entry.name, duration: entry.duration });
    }).observe({ type: "event", durationThreshold: 0, buffered: true } as PerformanceObserverInit);
    new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) w.benchLong.push([entry.startTime, entry.duration]);
    }).observe({ type: "longtask", buffered: true });
  });
  await page.goto(`http://127.0.0.1:${statics.port}/#n=${count}`);
  await page.waitForFunction(() => (window as unknown as { benchReady?: boolean }).benchReady === true);
  await page.waitForTimeout(400);
  const trigger = page.locator(".acpmux-location-button");
  const box = (await trigger.boundingBox())!;
  const press = async () => {
    await page.evaluate(() => ((window as unknown as { benchEvents: unknown[] }).benchEvents.length = 0));
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.waitForSelector(".acpmux-folder-popover .acpmux-location-row");
    await page.mouse.up();
    // Event Timing entries arrive after their frame.
    await page.waitForTimeout(150);
    return page.evaluate(() => {
      const events = (window as unknown as { benchEvents: { name: string; duration: number }[] }).benchEvents;
      return Math.max(0, ...events.filter((e) => e.name === "pointerdown").map((e) => e.duration));
    });
  };
  const openedAt = await page.evaluate(() => performance.now());
  const open = await press();
  await page.waitForTimeout(1000);
  const rows = await page.locator(".acpmux-folder-popover .acpmux-menu-item").count();
  const { settle, asks } = await page.evaluate((from) => {
    const w = window as unknown as { benchLong: number[][]; benchIconAsks: number };
    const settle = w.benchLong
      .filter(([start]) => start! >= from && start! < from + 1200)
      .reduce((sum, [, duration]) => sum + duration!, 0);
    return { settle, asks: w.benchIconAsks };
  }, openedAt);
  // Filtering: three letters, each to its next paint.
  let filter = 0;
  for (const key of ["p", "r", "o"]) {
    await page.evaluate(() => ((window as unknown as { benchEvents: unknown[] }).benchEvents.length = 0));
    await page.keyboard.press(key);
    await page.waitForTimeout(200);
    const duration = await page.evaluate(() => {
      const events = (window as unknown as { benchEvents: { name: string; duration: number }[] }).benchEvents;
      return Math.max(0, ...events.filter((e) => e.name === "keydown" || e.name === "keypress").map((e) => e.duration));
    });
    filter = Math.max(filter, duration);
  }
  await page.keyboard.press("Escape");
  await page.waitForSelector(".acpmux-folder-popover", { state: "detached" });
  await page.waitForTimeout(300);
  const reopen = await press();
  await context.close();
  return { open, reopen, filter, settle, rows, asks };
}

const lines: string[] = [];
for (const count of COUNTS) {
  const rounds: Round[] = [];
  for (let index = 0; index < ROUNDS; index++) rounds.push(await round(count));
  const pick = (key: keyof Round) => median(rounds.map((r) => r[key]));
  const line =
    `project-picker-open n=${count} rounds=${ROUNDS} openMs=${pick("open").toFixed(0)} reopenMs=${pick("reopen").toFixed(0)} ` +
    `filterMs=${pick("filter").toFixed(0)} settleLongTaskMs=${pick("settle").toFixed(0)} rows=${pick("rows")} iconAsks=${pick("asks")}`;
  console.log(line);
  lines.push(line);
}
if (process.env.FAST_CHECKS_OUT)
  fs.writeFileSync(path.join(process.env.FAST_CHECKS_OUT, "project-picker-open.txt"), lines.join("\n") + "\n");
await browser.close();
await statics.stop(true);
fs.rmSync(out, { recursive: true, force: true });
