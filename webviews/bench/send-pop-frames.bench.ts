// l10n-allow-file: bench fixture prompts, not shipped UI.
// Frame times while a sent prompt pops in (conversation.css SEND-POP; Leo 2026-11-22: "dang it's CUTE and so much
// NICER FEELING than just a jarring instant send"; on why it was stripped: "i stripped it earlier bc we kept
// lagging"). The production pane (a vite build of its dev entry, on the in-page mock daemon) opens a chat of
// `--turns` finished turns (`cmuxAcpmuxDebug.loadSeed`), the reader types a prompt and presses Return, and a frame
// callback loop records every frame for the pop's span (Return to 600 ms after). Chromium also traces the
// renderer's main thread over that span: the pop is a transform on one wrapper, so it should add no Layout,
// style or Paint work per frame, whatever the chat's length.
//   bun bench/send-pop-frames.bench.ts [rounds=5] [--engines chromium,webkit] [--turns N] [--load MS]
//       [--pop product|none] [--json FILE]
//   --turns N  the chat's finished turns before the send (4; 1000 is a long chat)
//   --load MS  every frame busy-waits MS and a 120 ms long task runs every 500 ms (send-motion-pass.bench.ts
//              `--load`): a loaded machine
//   --pop none sets `data-send-pop="none"` on the page: the instant send before (#42669), from the same build,
//              so before and after are one harness; --pop paired alternates none and product round by round on
//              one page, so a busy machine's drift lands on both arms alike
// Reported per engine, the median over rounds: frame p50 and p95 (ms between frames), dropped (frames past one
// 16.7 ms interval the span missed: a 50 ms gap is two), and on Chromium layoutMs, styleMs and paintMs summed over
// the span; popped says the pop's animation ran in that round (1) or not (0).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type { Browser, Page } from "playwright";
import { chromium, webkit } from "./browsers";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(name);
  return at >= 0 ? argv[at + 1] : undefined;
};
const VALUED = new Set(["--engines", "--turns", "--load", "--pop", "--json"]);
const ROUNDS = Number(argv.find((arg, index) => /^\d+$/.test(arg) && !VALUED.has(argv[index - 1] ?? "")) ?? 5);
const ENGINES = (flag("--engines") ?? "chromium,webkit").split(",");
const TURNS = Number(flag("--turns") ?? 4);
const LOAD_MS = Number(flag("--load") ?? 0);
const POP = flag("--pop") ?? "product";
const JSON_OUT = flag("--json");
const SPAN_MS = 600;
const VSYNC_MS = 1000 / 60;
const field = '.acpmux-composer-prompt [contenteditable="true"]';
const log = (...args: unknown[]) => console.error("send-pop-frames:", ...args);
const webviews = path.resolve(import.meta.dir, "..");

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  pid: number;
  args?: { name?: string };
};
type Round = {
  p50: number;
  p95: number;
  dropped: number;
  frames: number;
  popped: number;
  layoutMs?: number;
  styleMs?: number;
  paintMs?: number;
};

const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-pop-pane-"));
await build({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out, emptyOutDir: true },
  logLevel: "error",
});
const pane = await preview({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out },
  preview: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const url = `${pane.resolvedUrls!.local[0]!.replace(/\/$/, "")}/?mock`;

const quantile = (values: number[], q: number) => {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(q * (sorted.length - 1)))]! : 0;
};
const median = (values: number[]) => quantile(values, 0.5);

async function open(browser: Browser): Promise<Page> {
  const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  await page.addInitScript(() => Object.assign(window, { cmuxFrameBudget: "on" }));
  await page.goto(url);
  await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 60_000 });
  const seeded = (await page.evaluate(
    (turns) =>
      (
        window as unknown as { cmuxAcpmuxDebug: { loadSeed(turns: number): Promise<unknown> } }
      ).cmuxAcpmuxDebug.loadSeed(turns),
    TURNS,
  )) as { error?: string };
  if (seeded.error) throw new Error(`seed ${TURNS}: ${seeded.error}`);
  await page.locator(field).waitFor({ timeout: 60_000 });
  // The product's pop is off unless switched on (agentPane.display.sendPop): "product" sets its root gate.
  if (POP !== "paired")
    await page.evaluate(
      (pop) => document.documentElement.setAttribute("data-send-pop", pop),
      POP === "product" ? "claude" : POP,
    );
  return page;
}

async function round(page: Page, index: number, trace: boolean): Promise<Round> {
  await page.locator(field).click();
  await page.keyboard.type(`round ${index}: it does a little pop and settle, so much nicer than a jarring send`);
  await page.waitForTimeout(300);
  // The frame loop and the load start before the Return; the span is read from the Return on.
  await page.evaluate(
    ({ load }) => {
      const w = window as unknown as { __frames: number[]; __stop: () => void };
      w.__frames = [];
      let running = true;
      const frame = (now: number) => {
        if (!running) return;
        if (load > 0) {
          const until = performance.now() + load;
          while (performance.now() < until) {
            // Hold the main thread, as a loaded machine does.
          }
        }
        w.__frames.push(now);
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
      const long =
        load > 0
          ? setInterval(() => {
              const until = performance.now() + 120;
              while (performance.now() < until) {
                // A long task.
              }
            }, 500)
          : undefined;
      w.__stop = () => {
        running = false;
        if (long) clearInterval(long);
      };
    },
    { load: LOAD_MS },
  );
  if (trace)
    await page
      .context()
      .browser()!
      .startTracing(page, { categories: ["devtools.timeline"] });
  const sentAt = await page.evaluate(() => performance.now());
  await page.keyboard.press("Enter");
  // One read, mid-pop, of whether the pop ran: a read every frame would itself cost the frames measured.
  await page.waitForTimeout(150);
  const poppedNow = await page.evaluate(() =>
    document.getAnimations().some((animation) => (animation as CSSAnimation).animationName?.startsWith("cv-send-pop")),
  );
  await page.waitForTimeout(SPAN_MS - 50);
  const traced = trace ? await page.context().browser()!.stopTracing() : undefined;
  const frames = await page.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __stop: () => void };
    w.__stop();
    return w.__frames;
  });
  const popped = poppedNow;
  const span = frames.filter((at) => at >= sentAt && at <= sentAt + SPAN_MS);
  const gaps = span.slice(1).map((at, index) => at - span[index]!);
  const result: Round = {
    p50: Number(median(gaps).toFixed(2)),
    p95: Number(quantile(gaps, 0.95).toFixed(2)),
    dropped: gaps.reduce((total, gap) => total + Math.max(0, Math.round(gap / VSYNC_MS) - 1), 0),
    frames: span.length,
    popped: popped ? 1 : 0,
  };
  if (traced) {
    const events = (JSON.parse(traced.toString()) as { traceEvents: TraceEvent[] }).traceEvents;
    const main = events.find((event) => event.name === "thread_name" && event.args?.name === "CrRendererMain");
    const start = events.find((event) => event.name === "TracingStartedInBrowser")?.ts ?? 0;
    const onMain = events.filter(
      (e) => main && e.pid === main.pid && e.tid === main.tid && e.ph === "X" && e.ts >= start,
    );
    const sum = (names: string[]) =>
      Number(
        onMain
          .filter((event) => names.includes(event.name))
          .reduce((total, event) => total + (event.dur ?? 0) / 1000, 0)
          .toFixed(2),
      );
    result.layoutMs = sum(["Layout"]);
    result.styleMs = sum(["UpdateLayoutTree"]);
    result.paintMs = sum(["Paint", "PrePaint"]);
  }
  // The mock's turn runs on; the next round waits for it to end.
  await page
    .getByRole("button", { name: "Stop" })
    .waitFor({ state: "detached", timeout: 30_000 })
    .catch(() => undefined);
  await page.waitForTimeout(400);
  return result;
}

const report: Record<string, { rounds: Round[]; median: Record<string, number> }> = {};
try {
  for (const engine of ENGINES) {
    const type = engine === "webkit" ? webkit : chromium;
    const browser = await type.launch({ headless: true });
    try {
      const page = await open(browser);
      // One warm-up send, not counted: the first send loads lazy chunks.
      await round(page, -1, false);
      const arms: Record<string, Round[]> = {};
      for (let index = 0; index < ROUNDS * (POP === "paired" ? 2 : 1); index++) {
        const arm = POP === "paired" ? (index % 2 === 0 ? "none" : "product") : POP;
        if (POP === "paired")
          await page.evaluate((value) => {
            document.documentElement.setAttribute("data-send-pop", value === "product" ? "claude" : value);
          }, arm);
        (arms[arm] ??= []).push(await round(page, index, engine === "chromium"));
      }
      for (const [arm, rounds] of Object.entries(arms)) {
        const keys = Object.keys(rounds[0]!) as (keyof Round)[];
        const summary = Object.fromEntries(keys.map((key) => [key, median(rounds.map((r) => r[key] ?? 0))]));
        report[`${engine}:${arm}`] = { rounds, median: summary };
        log(`${engine} turns=${TURNS} load=${LOAD_MS} pop=${arm} rounds=${rounds.length}`);
        console.log(JSON.stringify({ engine, turns: TURNS, load: LOAD_MS, pop: arm, median: summary }));
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await pane.close();
  fs.rmSync(out, { recursive: true, force: true });
}
if (JSON_OUT) fs.writeFileSync(JSON_OUT, JSON.stringify({ turns: TURNS, load: LOAD_MS, pop: POP, report }, null, 2));
