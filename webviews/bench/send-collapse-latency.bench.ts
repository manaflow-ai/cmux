// l10n-allow-file: benchmark output and fixture prompts, not shipped UI.
// How long a tall draft's composer takes to collapse once Enter sends it (Leo, 2026-11-22, ask-fac73c9b41: "IT'S
// LIKE SOME B******T I THINK WHEN IT'S SUPER / MULTI / LINE / AND THEN / THE F******G COLLAPSING OF THE F*****G
// COMPOSER / IT TAKES TOO F*****G LONG OR WHATEVER!?").
//
// The real pane (`?mock`: the real direct client against the in-page mock daemon), built as it ships (React's
// production build), on Chromium. A light chat of `--lengths` turns (cmuxAcpmuxDebug.loadSeed), then a draft of
// `--lines` lines typed with real keys (Shift-Return between lines), then Return. Per send:
//   collapse_ms  Return's keydown to the first frame drawn with the composer at its resting height: the frame the
//                person sees the composer collapse (read as the next frame's start, after that frame painted)
//   frame_ms     how long the frame that draws the collapse took (long-animation-frame duration; 0 if under 50 ms)
//   observer_ms  of that, the transcript's stack observer (VirtualTranscript `resized`, ResizeObserver callbacks)
// The median over `--rounds` sends per length and line count. CPU=N (default 4) slows the page's CPU N times, as a
// loaded machine is (send-motion-frames.bench.ts does the same). LABEL names the run.
//   bun bench/send-collapse-latency.bench.ts [--lengths 60,1500] [--lines 1,5,15,40] [--rounds 5]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import { servePane } from "./composer-arms";
import { seedComposer } from "./composer-load";
import { reportTrace, traceWindow } from "./styleInvalidationTrace";

const argv = process.argv.slice(2);
const flag = (name: string) => {
  const at = argv.indexOf(`--${name}`);
  return at >= 0 ? argv[at + 1] : undefined;
};
const list = (name: string, fallback: string) => (flag(name) ?? fallback).split(",").map(Number);
const LENGTHS = list("lengths", "60,1500");
const LINES = list("lines", "1,5,15,40");
const ROUNDS = Number(flag("rounds") ?? 5);
const CPU = Number(process.env.CPU ?? 4);
const LABEL = process.env.LABEL ?? "build";
const FIELD = ".acpmux-composer-prompt [contenteditable='true']";
const log = (...args: unknown[]) => console.error("send-collapse-latency:", ...args);
const median = (values: number[]) => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)] ?? 0;

const releases: (() => unknown)[] = [];
const port = await servePane(
  path.resolve(import.meta.dir, ".."),
  {
    unminified: Boolean(process.env.UNMINIFIED),
    built: (out) => process.env.KEEP && Bun.spawnSync(["cp", "-r", out, process.env.KEEP]),
  },
  releases,
);
const browser = await chromium.launch({ headless: true });
releases.push(() => browser.close());

type Probe = { collapseMs: number; frameMs: number; observerMs: number; fromH: number; toH: number; scripts: string[] };

const results: Record<string, unknown>[] = [];
try {
  for (const length of LENGTHS) {
    const page = await browser.newPage({ viewport: { width: 900, height: 720 } });
    await page.goto(`http://127.0.0.1:${port}/?mock`);
    await seedComposer(page, length);
    if (process.env.DROP)
      log(
        "dropped",
        await page.evaluate(
          ([range, all]) => {
            const [from, to] = /^\d+-\d+$/.test(range) ? (range.split("-").map(Number) as [number, number]) : [0, 1e9];
            const found: [CSSStyleSheet | CSSGroupingRule, CSSStyleRule][] = [];
            const sweep = (list: CSSRuleList, owner: CSSStyleSheet | CSSGroupingRule) => {
              for (const rule of list) {
                if (rule instanceof CSSStyleRule && rule.selectorText.includes(":has(")) found.push([owner, rule]);
                if ("cssRules" in rule) sweep((rule as CSSGroupingRule).cssRules, rule as CSSGroupingRule);
              }
            };
            for (const sheet of document.styleSheets) sweep(sheet.cssRules, sheet);
            const chosen = /^\d+-\d+$/.test(range)
              ? found.slice(from, to)
              : found.filter(([, rule]) => rule.selectorText.includes(range));
            for (const [owner, rule] of chosen) owner.deleteRule([...owner.cssRules].indexOf(rule));
            const names = chosen.map(([, rule]) => rule.selectorText.replace(/\s+/g, " ").slice(0, 240));
            return (
              `${chosen.length}/${found.length}` +
              (chosen.length <= 12 || all
                ? `\n${names.map((name, at) => `  ${found.indexOf(chosen[at]!)}: ${name}`).join("\n")}`
                : "")
            );
          },
          [process.env.DROP, Boolean(process.env.DROP_NAMES)] as const,
        ),
      );
    const cdp = await page.context().newCDPSession(page);
    await cdp.send("Emulation.setCPUThrottlingRate", { rate: CPU });
    for (const lines of LINES) {
      const runs: Probe[] = [];
      for (let round = 0; round < ROUNDS; round += 1) {
        await page.locator(FIELD).click();
        const restH = await page.evaluate(
          () => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
        );
        for (let line = 1; line <= lines; line += 1) {
          await page.keyboard.insertText(`round ${round} line ${line} of a tall draft to send`);
          if (line < lines) await page.keyboard.press("Shift+Enter");
        }
        await page.waitForTimeout(600 + 100 * CPU);
        await page.evaluate((restH) => {
          const box = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
          const state = {
            fromH: box.getBoundingClientRect().height,
            keyAt: -1,
            drawnAt: -1,
            frames: [] as PerformanceEntry[],
          };
          (window as any).__collapse = state;
          const observer = new PerformanceObserver((list) => state.frames.push(...list.getEntries()));
          observer.observe({ type: "long-animation-frame", buffered: false });
          (state as any).observer = observer;
          addEventListener(
            "keydown",
            (event) => {
              if ((event as KeyboardEvent).key !== "Enter") return;
              state.keyAt = event.timeStamp;
              // The first frame whose layout has the prompt empty and the composer back at its resting height; the
              // next frame's start is after that frame painted.
              const field = box.querySelector(".acpmux-composer-prompt [contenteditable='true']");
              const watch = () => {
                if (!field?.textContent?.trim() && box.getBoundingClientRect().height <= restH + 2)
                  requestAnimationFrame(() => (state.drawnAt = performance.now()));
                else requestAnimationFrame(watch);
              };
              requestAnimationFrame(watch);
            },
            { capture: true, once: true },
          );
        }, restH);
        const profiling = process.env.PROFILE && round === ROUNDS - 1;
        if (profiling) {
          await cdp.send("Profiler.enable");
          await cdp.send("Profiler.setSamplingInterval", { interval: 100 });
          await cdp.send("Profiler.start");
        }
        const tracing = process.env.TRACE && round === ROUNDS - 1;
        const traced = tracing
          ? await traceWindow(browser, page, async () => {
              await page.keyboard.press("Enter");
              await page.waitForFunction(() => (window as any).__collapse.drawnAt > 0, null, { timeout: 30_000 });
            })
          : (await page.keyboard.press("Enter"), undefined);
        if (traced)
          await reportTrace(
            `send ${length}x${lines}`,
            traced,
            { keys: 1 },
            (url, line) => `${url.split("/").pop()}:${line + 1}`,
            cdp,
          );
        await page
          .waitForFunction(() => (window as any).__collapse.drawnAt > 0, null, { timeout: 30_000 })
          .catch(async (error) => {
            const seen = await page.evaluate(() => ({
              keyAt: (window as any).__collapse.keyAt,
              text: document.querySelector(".acpmux-composer-prompt")?.textContent?.slice(0, 80),
              h: document.querySelector(".acpmux-composer-box")?.getBoundingClientRect().height,
              from: (window as any).__collapse.fromH,
            }));
            throw new Error(`no collapse: ${JSON.stringify(seen)} (${String(error)})`);
          });
        await page.waitForTimeout(150);
        if (profiling) {
          const { profile } = await cdp.send("Profiler.stop");
          await Bun.write(`${process.env.PROFILE}-${length}-${lines}.cpuprofile`, JSON.stringify(profile));
        }
        const probe = await page.evaluate((): Probe => {
          const state = (window as any).__collapse;
          state.observer.disconnect();
          const frame = (state.frames as any[]).find(
            (entry) => entry.startTime + entry.duration >= state.keyAt && entry.startTime <= state.drawnAt,
          );
          const scripts = (frame?.scripts ?? []) as any[];
          return {
            collapseMs: state.drawnAt - state.keyAt,
            frameMs: frame?.duration ?? 0,
            observerMs: scripts
              .filter((script) => script.invoker === "ResizeObserverCallback")
              .reduce((sum, script) => sum + script.duration, 0),
            scripts: scripts
              .filter((script) => script.duration > 4)
              .map(
                (script) =>
                  `${script.invoker} ${script.sourceFunctionName}@${String(script.sourceURL).split("/").pop()}:${script.sourceCharPosition} ${Math.round(script.duration)}ms forced=${Math.round(script.forcedStyleAndLayoutDuration)}`,
              ),
            fromH: state.fromH,
            toH: document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().height,
          };
        });
        runs.push(probe);
        await page
          .getByRole("button", { name: "Stop" })
          .waitFor({ state: "detached", timeout: 60_000 })
          .catch(() => undefined);
        await page.waitForTimeout(300);
      }
      const row = {
        label: LABEL,
        cpu: CPU,
        length,
        lines,
        rounds: ROUNDS,
        composer_px: `${Math.round(runs[0]!.fromH)}->${Math.round(runs[0]!.toH)}`,
        collapse_ms: Math.round(median(runs.map((run) => run.collapseMs))),
        collapse_ms_max: Math.round(Math.max(...runs.map((run) => run.collapseMs))),
        frame_ms: Math.round(median(runs.map((run) => run.frameMs))),
        observer_ms: Math.round(median(runs.map((run) => run.observerMs))),
      };
      log(JSON.stringify(row));
      if (process.env.SCRIPTS) for (const script of runs.at(-1)!.scripts) log("  ", script);
      results.push(row);
    }
    await page.close();
  }
  console.log(JSON.stringify(results));
} finally {
  for (const release of releases.reverse()) await release();
}
