// l10n-allow-file: bench fixture drafts, not shipped UI.
// How long the composer takes to fall back to its one-line height from a tall draft. Leo, 2026-11-22:
// "IT'S LIKE SOME BULLSHIT I THINK WHEN IT'S SUPER / MULTI / LINE / AND THEN / THE FUCSKING COLLAPSING OF
// THE FUCKING COMPOSER / IT TAKES TOO FUCKING LONG OR WHATEVER!?"
//   bun bench/composer-collapse.bench.ts [rounds=3]
// CPU=N (default 1) slows the page's CPU N times (CDP Emulation.setCPUThrottlingRate). LINES=5,50,300,2000
// picks the draft sizes; LABEL names the run (the before/after of one harness).
// The real pane (its dev entry with the mock agent, a production build, as send-motion-frames.bench.ts) on
// Chromium. Per draft size and action (Enter sends; select-all then Delete clears): the draft is pasted,
// the field rests at its cap, the action's key is pressed, and the page reports
//   taskMs: the longest main-thread task from the key to the field at rest (CDP trace, RunTask);
//   restMs: from the key's event to the first painted frame of the field at its one-line height, held;
//   moveFrames: painted frames whose field height was between its start and its rest height (motion).
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "./browsers";
import type { Page } from "playwright";
import { COMPOSER_MD_FIELD } from "../src/agent-session/acpmux/composerSelectors";

const ROUNDS = Number(process.argv[2] ?? 3);
const CPU = Number(process.env.CPU ?? 1);
const LABEL = process.env.LABEL ?? "build";
const SIZES = (process.env.LINES ?? "5,50,300,2000,block").split(",");
const webviews = path.resolve(import.meta.dir, "..");
const editor = '.acpmux-composer-prompt [contenteditable="true"]';
const log = (...args: unknown[]) => console.error("composer-collapse:", ...args);

type TraceEvent = {
  name: string;
  ph: string;
  ts: number;
  dur?: number;
  tid: number;
  pid: number;
  args?: { name?: string };
};

const { build, preview } = await import("vite");
const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "composer-collapse-pane-"));
await build({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out, emptyOutDir: true, ...(process.env.PROFILE ? { minify: false } : {}) },
  logLevel: "error",
});
const pane = await preview({
  configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
  build: { outDir: out },
  preview: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
const browser = await chromium.launch({ headless: true });

function draft(size: string): string {
  // One long pasted block: a single paragraph of ~40k characters.
  if (size === "block") return Array.from({ length: 800 }, (_, i) => `word${i} of the long pasted block`).join(" ");
  return Array.from({ length: Number(size) }, (_, i) => `Line ${i + 1} of the draft, a few more words here`).join(
    "\n\n",
  );
}

async function sampler(page: Page) {
  await page.evaluate((selector) => {
    const w = window as unknown as {
      __collapse: { start(): void; frames: { t: number; h: number }[]; key: number };
    };
    let stop = true;
    w.__collapse = {
      frames: [],
      key: 0,
      start() {
        w.__collapse.frames = [];
        w.__collapse.key = 0;
        stop = false;
        const tick = () => {
          if (stop) return;
          const field = document.querySelector<HTMLElement>(selector);
          if (field) w.__collapse.frames.push({ t: performance.now(), h: field.getBoundingClientRect().height });
          if (w.__collapse.frames.length > 600) stop = true;
          else requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        document.addEventListener(
          "keydown",
          (event) => {
            if (event.key === "Enter" || event.key === "Delete") w.__collapse.key = event.timeStamp;
          },
          { capture: true, once: false },
        );
      },
    };
  }, COMPOSER_MD_FIELD);
}

const fieldHeight = (page: Page) =>
  page.evaluate(
    (selector) => document.querySelector<HTMLElement>(selector)!.getBoundingClientRect().height,
    COMPOSER_MD_FIELD,
  );

async function fill(page: Page, text: string) {
  await page.locator(editor).click();
  await page.evaluate(
    ({ selector, text }) => {
      // Set as the draft (the handle's `type`, as a restored draft): a paste this long would become a
      // pasted-text chip, and the bench measures a tall field.
      const field = document.querySelector(selector) as unknown as { acpmuxMarkdownField: { type(t: string): void } };
      field.acpmuxMarkdownField.type(text);
    },
    { selector: COMPOSER_MD_FIELD, text },
  );
  await page.waitForTimeout(600);
}

const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0;

const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
await page.addInitScript(() => {
  Object.assign(window, {
    webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
    cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
  });
});
await page.goto(pane.resolvedUrls!.local[0]!);
await page.locator(editor).waitFor();
await sampler(page);
const cdp = await page.context().newCDPSession(page);
await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
await page.waitForTimeout(500);
const rest = await fieldHeight(page);
log(`rest height ${rest}`);

const rows: Record<string, unknown>[] = [];
for (const size of SIZES) {
  for (const action of ["send", "delete"] as const) {
    const results: { taskMs: number; restMs: number; moveFrames: number; from: number }[] = [];
    for (let round = 0; round < ROUNDS; round++) {
      await fill(page, draft(size));
      const from = await fieldHeight(page);
      await browser.startTracing(page, { categories: ["devtools.timeline", "toplevel"] });
      await page.evaluate(() => (window as unknown as { __collapse: { start(): void } }).__collapse.start());
      if (process.env.PROFILE) {
        await cdp.send("Profiler.enable");
        await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
        await cdp.send("Profiler.start");
      }
      if (action === "send") await page.keyboard.press("Enter");
      else {
        await page.keyboard.press("ControlOrMeta+a");
        await page.keyboard.press("Delete");
      }
      await page.waitForFunction(
        ({ selector, rest }) =>
          Math.abs(document.querySelector<HTMLElement>(selector)!.getBoundingClientRect().height - rest) < 0.5,
        { selector: COMPOSER_MD_FIELD, rest },
        { timeout: 60_000, polling: "raf" },
      );
      await page.waitForTimeout(300 * CPU);
      if (process.env.PROFILE) {
        const { profile } = (await cdp.send("Profiler.stop")) as unknown as {
          profile: {
            nodes: {
              id: number;
              callFrame: { functionName: string; url: string; lineNumber: number };
              children?: number[];
            }[];
            samples: number[];
            timeDeltas: number[];
          };
        };
        const self = new Map<number, number>();
        profile.samples.forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (profile.timeDeltas[i] ?? 0) / 1000));
        const byId = new Map(profile.nodes.map((n) => [n.id, n]));
        const parent = new Map<number, number>();
        for (const n of profile.nodes) for (const c of n.children ?? []) parent.set(c, n.id);
        const selfBy = new Map<string, number>();
        const totalBy = new Map<string, number>();
        for (const [id, ms] of self) {
          const n = byId.get(id)!;
          const key = (x: typeof n) =>
            `${x.callFrame.functionName || "(anon)"} ${x.callFrame.url.split("/").pop()}:${x.callFrame.lineNumber}`;
          selfBy.set(key(n), (selfBy.get(key(n)) ?? 0) + ms);
          const seen = new Set<string>();
          for (let cur: number | undefined = id; cur !== undefined; cur = parent.get(cur)) {
            const k = key(byId.get(cur)!);
            if (seen.has(k)) continue;
            seen.add(k);
            totalBy.set(k, (totalBy.get(k) ?? 0) + ms);
          }
        }
        // Who calls the layout and style reads (the parent frames of each sampled read).
        const callers = new Map<string, number>();
        for (const [id, ms] of self) {
          const n = byId.get(id)!;
          if (
            !["getBoundingClientRect", "getPropertyValue", "getComputedStyle", "(program)"].includes(
              n.callFrame.functionName,
            )
          )
            continue;
          const chain: string[] = [];
          for (let cur = parent.get(id); cur !== undefined && chain.length < 4; cur = parent.get(cur)) {
            const f = byId.get(cur)!.callFrame;
            chain.push(`${f.functionName || "(anon)"}:${f.lineNumber}`);
          }
          const k = `${n.callFrame.functionName} <- ${chain.join(" <- ")}`;
          callers.set(k, (callers.get(k) ?? 0) + ms);
        }
        const top = (m: Map<string, number>, n: number) =>
          [...m]
            .sort((a, b) => b[1] - a[1])
            .slice(0, n)
            .map(([k, v]) => `${v.toFixed(0)} ${k}`);
        log(`PROFILE ${size} ${action} self:\n  ${top(selfBy, 25).join("\n  ")}`);
        log(`PROFILE ${size} ${action} readers:\n  ${top(callers, 15).join("\n  ")}`);
        log(`PROFILE ${size} ${action} total:\n  ${top(totalBy, Number(process.env.TOP ?? 60)).join("\n  ")}`);
      }
      const trace = JSON.parse((await browser.stopTracing()).toString()) as { traceEvents: TraceEvent[] };
      const main = trace.traceEvents.find((e) => e.name === "thread_name" && e.args?.name === "CrRendererMain");
      const tasks = trace.traceEvents.filter(
        (e) =>
          main &&
          e.pid === main.pid &&
          e.tid === main.tid &&
          e.ph === "X" &&
          e.name === "ThreadControllerImpl::RunTask",
      );
      const taskMs = Math.max(0, ...tasks.map((e) => (e.dur ?? 0) / 1000));
      if (process.env.PARTS) {
        const longest = tasks.reduce((a, b) => ((b.dur ?? 0) > (a.dur ?? 0) ? b : a), tasks[0]!);
        const inside = trace.traceEvents.filter(
          (e) =>
            e.pid === longest.pid &&
            e.tid === longest.tid &&
            e.ph === "X" &&
            e.ts >= longest.ts &&
            e.ts + (e.dur ?? 0) <= longest.ts + (longest.dur ?? 0) &&
            e !== longest,
        );
        const parts = new Map<string, number>();
        for (const e of inside)
          if (
            [
              "Layout",
              "UpdateLayoutTree",
              "Paint",
              "PrePaint",
              "FunctionCall",
              "EventDispatch",
              "MinorGC",
              "MajorGC",
              "ParseHTML",
              "HitTest",
              "IntersectionObserverController::computeIntersections",
              "ScheduleStyleRecalculation",
              "UpdateLayerTree",
              "Layerize",
              "Commit",
              "RunMicrotasks",
              "v8.run",
              "TimerFire",
              "FireAnimationFrame",
              "ResizeObserver::BroadcastObservations",
            ].includes(e.name)
          )
            parts.set(e.name, (parts.get(e.name) ?? 0) + (e.dur ?? 0) / 1000);
        log("parts", JSON.stringify([...parts].map(([k, v]) => [k, Math.round(v)])));
        const layouts = inside
          .filter((e) => e.name === "Layout" || e.name === "UpdateLayoutTree")
          .sort((a, b) => (b.dur ?? 0) - (a.dur ?? 0))
          .slice(0, 6);
        log(
          "biggest layouts",
          JSON.stringify(
            layouts.map((e) => [e.name, Math.round((e.dur ?? 0) / 1000), Math.round((e.ts - longest.ts) / 1000)]),
          ),
        );
      }
      const { frames, key } = await page.evaluate(
        () => (window as unknown as { __collapse: { frames: { t: number; h: number }[]; key: number } }).__collapse,
      );
      const after = frames.filter((f) => f.t >= key);
      const landed = after.findIndex((f, i) => after.slice(i).every((g) => Math.abs(g.h - rest) < 0.5));
      const restMs = landed < 0 ? NaN : after[landed]!.t - key;
      const moveFrames = after.filter((f) => f.h < from - 0.5 && f.h > rest + 0.5).length;
      results.push({ taskMs, restMs, moveFrames, from });
      if (process.env.DEBUG) {
        const names = new Map<string, number>();
        for (const e of trace.traceEvents)
          if (e.ph === "X" && (e.dur ?? 0) > 5000)
            names.set(`${e.name}@${e.tid}`, Math.max(names.get(`${e.name}@${e.tid}`) ?? 0, (e.dur ?? 0) / 1000));
        log(
          "threads",
          JSON.stringify(trace.traceEvents.filter((e) => e.name === "thread_name").map((e) => [e.tid, e.args?.name])),
        );
        log("long", JSON.stringify([...names].sort((a, b) => b[1] - a[1]).slice(0, 12)));
        log("frames", JSON.stringify(after.map((f) => [Math.round(f.t - key), Math.round(f.h)])));
      }
      if (action === "send")
        await page.getByRole("button", { name: "Stop" }).waitFor({ state: "detached", timeout: 60_000 });
      await page.waitForTimeout(200);
    }
    const row = {
      size,
      action,
      fromPx: Math.round(results[0]!.from),
      taskMs: Number(median(results.map((r) => r.taskMs)).toFixed(1)),
      restMs: Number(median(results.map((r) => r.restMs)).toFixed(1)),
      moveFrames: median(results.map((r) => r.moveFrames)),
    };
    log(JSON.stringify(row));
    rows.push(row);
  }
}
console.log(JSON.stringify({ label: LABEL, cpu: CPU, rounds: ROUNDS, rest, rows }));
await browser.close();
await pane.close();
fs.rmSync(out, { recursive: true, force: true });
