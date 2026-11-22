// l10n-allow-file: bench fixture prompts, not shipped UI.
// Frame times and the seat while a prompt is sent under Sent Prompt Placement (chatDisplay.ts
// SEND_PLACEMENT_KEY, conversation/sendSeat.ts; Leo 2026-11-22: "the wider sweeping situation with having
// there be a bunch of extra space at the bottom is not something we need to emulate (other than our claude
// code customization emulation repo)"). The harness is send-pop-frames.bench.ts's: the production pane (a vite
// build of its dev entry, on the in-page mock daemon) opens a chat of `--turns` finished turns, the reader
// types a prompt and presses Return, and a frame callback loop records every frame from the Return to 600 ms
// after; Chromium traces the main thread over that span. `latest` (the default) and `top` alternate round by
// round on one page (`--placement paired`, through dev.tsx's `cmuxDevDisplay`, the host's display push), so
// before and after are one harness on one machine.
//   bun bench/send-placement-frames.bench.ts [rounds=5] [--engines chromium,webkit] [--turns N] [--load MS]
//       [--placement latest|top|paired] [--json FILE]
// Reported per engine and arm, the median over rounds: frame p50 and p95, dropped frames, Chromium's layoutMs,
// styleMs and paintMs over the span, swept (the thread's sweep animation ran: 1 or 0), promptTop (the sent
// prompt's top under the scroller's top, px, at rest) and roomBelow (the scroller's foot less the last row's
// bottom, px, at rest: the room held for the reply).
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
const VALUED = new Set(["--engines", "--turns", "--load", "--placement", "--json"]);
const ROUNDS = Number(argv.find((arg, index) => /^\d+$/.test(arg) && !VALUED.has(argv[index - 1] ?? "")) ?? 5);
const ENGINES = (flag("--engines") ?? "chromium,webkit").split(",");
const TURNS = Number(flag("--turns") ?? 4);
const LOAD_MS = Number(flag("--load") ?? 0);
const PLACEMENT = flag("--placement") ?? "paired";
const JSON_OUT = flag("--json");
const SPAN_MS = 600;
const VSYNC_MS = 1000 / 60;
const field = '.acpmux-composer-prompt [contenteditable="true"]';
const log = (...args: unknown[]) => console.error("send-placement-frames:", ...args);
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
  swept: number;
  promptTop: number;
  roomBelow: number;
  layoutMs?: number;
  styleMs?: number;
  paintMs?: number;
};

const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "send-placement-pane-"));
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
  return page;
}

async function round(page: Page, index: number, trace: boolean): Promise<Round> {
  await page.locator(field).click();
  await page.keyboard.type(`round ${index}: the wider sweeping situation with a bunch of extra space at the bottom`);
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
  // One read, mid-sweep, of whether the thread's sweep ran: a read every frame would itself cost the frames.
  await page.waitForTimeout(100);
  const sweptNow = await page.evaluate(() =>
    document
      .getAnimations()
      .some((animation) => (animation.effect as KeyframeEffect | null)?.target?.classList?.contains("acpmux-thread")),
  );
  await page.waitForTimeout(SPAN_MS - 100);
  const traced = trace ? await page.context().browser()!.stopTracing() : undefined;
  const frames = await page.evaluate(() => {
    const w = window as unknown as { __frames: number[]; __stop: () => void };
    w.__stop();
    return w.__frames;
  });
  // At rest: where the sent prompt sits under the scroller's top, and the room under the last row.
  const seat = await page.evaluate(() => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    const prompts = [...document.querySelectorAll<HTMLElement>(".acpmux-row.acpmux-user")];
    const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")];
    if (!scroller || prompts.length === 0 || rows.length === 0) return { promptTop: -1, roomBelow: -1 };
    const view = scroller.getBoundingClientRect();
    const prompt = prompts.reduce((a, b) => (b.getBoundingClientRect().top > a.getBoundingClientRect().top ? b : a));
    const last = Math.max(...rows.map((row) => row.getBoundingClientRect().bottom));
    return { promptTop: prompt.getBoundingClientRect().top - view.top, roomBelow: view.bottom - last };
  });
  const span = frames.filter((at) => at >= sentAt && at <= sentAt + SPAN_MS);
  const gaps = span.slice(1).map((at, index) => at - span[index]!);
  const result: Round = {
    p50: Number(median(gaps).toFixed(2)),
    p95: Number(quantile(gaps, 0.95).toFixed(2)),
    dropped: gaps.reduce((total, gap) => total + Math.max(0, Math.round(gap / VSYNC_MS) - 1), 0),
    frames: span.length,
    swept: sweptNow ? 1 : 0,
    promptTop: Math.round(seat.promptTop),
    roomBelow: Math.round(seat.roomBelow),
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
      for (let index = 0; index < ROUNDS * (PLACEMENT === "paired" ? 2 : 1); index++) {
        const arm = PLACEMENT === "paired" ? (index % 2 === 0 ? "latest" : "top") : PLACEMENT;
        await page.evaluate(
          (value) =>
            (window as { cmuxDevDisplay?: (value: unknown) => void }).cmuxDevDisplay?.({
              "agentPane.display.sendPlacement": value,
            }),
          arm,
        );
        (arms[arm] ??= []).push(await round(page, index, engine === "chromium"));
      }
      for (const [arm, rounds] of Object.entries(arms)) {
        const keys = Object.keys(rounds[0]!) as (keyof Round)[];
        const summary = Object.fromEntries(keys.map((key) => [key, median(rounds.map((r) => r[key] ?? 0))]));
        report[`${engine}:${arm}`] = { rounds, median: summary };
        log(`${engine} turns=${TURNS} load=${LOAD_MS} placement=${arm} rounds=${rounds.length}`);
        console.log(JSON.stringify({ engine, turns: TURNS, load: LOAD_MS, placement: arm, median: summary }));
      }
    } finally {
      await browser.close();
    }
  }
} finally {
  await pane.close();
  fs.rmSync(out, { recursive: true, force: true });
}
if (JSON_OUT)
  fs.writeFileSync(JSON_OUT, JSON.stringify({ turns: TURNS, load: LOAD_MS, placement: PLACEMENT, report }, null, 2));
