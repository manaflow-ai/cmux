// l10n-allow-file: bench output labels, not shipped UI.
// Where a resize frame beside a long chat actually goes, by self time.
//
// transcript-resize-stream-shaping.bench.ts measured the frame (326 ms p50 at 100k rows while a
// reply streams) and ruled out the three things the pane instruments: its React body (`vt.body`
// p95 7.9 ms), its React commit (3.4 ms) and its layout math (`layoutConversation` plus
// `placeRows`, 1.1 ms), all at 33k rows against an 88 ms frame. So the cost is in code no span
// covers, and reading components cannot say which. This takes Chromium's own sampling profile
// over the same drag and prints the functions by self time, which can.
//
//   bun bench/transcript-resize-profile.bench.ts [rows=100000] [shaping=app] [top=25] [mode=drag|step]
//
// `step` profiles one width step instead of a drag: a split or a side panel resizes a chat pane
// once, and the pane at rest takes it whole (its rows measured, its settle after LIVE_RESIZE_MS).
// STEP_COUNT steps, each STEP_REST_MS apart so every one is a one-off resize, alternate between two
// widths both under the chat's column cap (every step rewraps the rows). It prints each step's
// frame (width write to the end of that frame's rendering step) and the main-thread time the
// profile sampled per step, frame and settle together, then the functions by self and by total time.
/// <reference types="bun" />
import { chromium } from "./browsers";
import {
  benchPositionals,
  buildLabel,
  devRequested,
  gotoBenchPage,
  requireProductionReact,
  serveBenchPage,
} from "./support/benchPage";

const args = benchPositionals();
const ROWS = Number(args[0] ?? 100_000);
const SHAPING = args[1] ?? "app";
const TOP = Number(args[2] ?? 25);
const MODE = args[3] ?? "drag";
if (MODE !== "drag" && MODE !== "step") throw new Error("mode must be drag or step");
/// `--dev` takes the number from a dev server instead of the build, labelled `dev`: React is then
/// its development bundle, whose commit-phase instrumentation was about a third of every frame of
/// this drag (bench/support/benchPage.ts).
const DEV = devRequested();
if (!Number.isInteger(ROWS) || ROWS < 3) throw new Error("usage: [rows>=3] [shaping=scratch|app] [top]");
if (SHAPING !== "scratch" && SHAPING !== "app") throw new Error("shaping must be scratch or app");

const WIDE = 900;
const NARROW = 520;
const STEPS = 90;
/// `step` mode: the two widths a step goes between (both under the 800px column cap), how many
/// steps, and the rest after each one (past LIVE_RESIZE_MS, its settle, and any timer it armed).
const STEP_WIDTHS = [760, 700] as const;
const STEP_COUNT = 20;
const STEP_REST_MS = 700;

/// Chromium's sampling profile: the call tree, the node each sample landed in, and the time between
/// samples. Self time per node is the sum of the deltas of the samples that landed in it.
type Profile = {
  nodes: Array<{
    id: number;
    callFrame: { functionName: string; url: string; lineNumber: number };
    children?: number[];
  }>;
  samples: number[];
  timeDeltas: number[];
};


/// Prints the profile's main-thread time, then the functions by self time and by total time (a
/// function's own samples and those of everything it called). `steps` > 0 also prints it per step.
function printProfile(profile: Profile, steps: number, top = TOP) {
  const parent = new Map<number, number>();
  for (const node of profile.nodes) for (const child of node.children ?? []) parent.set(child, node.id);
  const keyOf = new Map<number, string>();
  // Self time per call frame, named by function and source line so a reader can go straight to it.
  const byNode = new Map<number, number>();
  for (let index = 0; index < profile.samples.length; index += 1) {
    const node = profile.samples[index]!;
    // A sample's delta is the time since the sample before it, which that sample's node owns.
    byNode.set(node, (byNode.get(node) ?? 0) + (profile.timeDeltas[index] ?? 0) / 1000);
  }
  const named = new Map<string, number>();
  let total = 0;
  for (const node of profile.nodes) {
    const frame = node.callFrame;
    const file = frame.url.replace(/^https?:\/\/[^/]+/, "").replace(/\?.*$/, "");
    const name = frame.functionName || "(anonymous)";
    keyOf.set(node.id, file ? `${name} ${file}:${frame.lineNumber + 1}` : name);
  }
  const inclusive = new Map<string, number>();
  for (const node of profile.nodes) {
    const ms = byNode.get(node.id);
    if (ms === undefined || ms <= 0) continue;
    const key = keyOf.get(node.id)!;
    if (key === "(idle)") continue;
    total += ms;
    named.set(key, (named.get(key) ?? 0) + ms);
    // Each function once per sample, however deep it recursed.
    const seen = new Set<string>();
    for (let at: number | undefined = node.id; at !== undefined; at = parent.get(at)) {
      const up = keyOf.get(at)!;
      if (seen.has(up)) continue;
      seen.add(up);
      inclusive.set(up, (inclusive.get(up) ?? 0) + ms);
    }
  }
  console.log(`resize-profile sampled ${Math.round(total)} ms of main-thread work (idle excluded)`);
  if (steps > 0) console.log(`resize-step main-thread work per step ${(total / steps).toFixed(1)} ms`);
  console.log("");
  console.log(`| self ms | share | function |`);
  console.log(`|---|---|---|`);
  for (const [key, ms] of [...named.entries()].sort((a, b) => b[1] - a[1]).slice(0, top))
    console.log(`| ${Math.round(ms)} | ${((ms / total) * 100).toFixed(1)}% | ${key} |`);
  console.log("");
  console.log(`| total ms | share | function |`);
  console.log(`|---|---|---|`);
  for (const [key, ms] of [...inclusive.entries()].sort((a, b) => b[1] - a[1]).slice(0, top * 2))
    console.log(`| ${Math.round(ms)} | ${((ms / total) * 100).toFixed(1)}% | ${key} |`);
}

const pagePath = "/test/browser/transcript-fling.html";
// Names, not mangled identifiers: this bench prints a profile by function name, and a build is
// minified by default.
const served = await serveBenchPage(pagePath, { dev: DEV, unminified: true });
const browser = await chromium.launch({ headless: true, args: ["--js-flags=--expose-gc"] });
try {
  const page = await browser.newPage({ viewport: { width: WIDE + 100, height: 900 } });
  await gotoBenchPage(page, served);
  await page.waitForFunction(() => "__shaping" in window && "__debug" in window);
  // Before any number is taken: a development React bundle is refused unless this run asked for one.
  await requireProductionReact(page, { dev: served.dev });
  await page.evaluate((shape) => (window as unknown as { __shaping: (m: string) => void }).__shaping(shape), SHAPING);
  const seeded = await page.evaluate(`window.__debug.seedRows(${ROWS})`);
  console.log(
    `resize-profile build=${buildLabel(served)} shaping=${SHAPING} rows=${ROWS} fixture=${JSON.stringify(seeded)}`,
  );

  const cdp = await page.context().newCDPSession(page);
  await cdp.send("Profiler.enable");
  // 100 µs between samples: a 326 ms frame gives ~3,000 samples, enough to separate the functions
  // that own it from the ones that merely appear in it.
  await cdp.send("Profiler.setSamplingInterval", { interval: 100 });

  // Settle at the wide width, following the latest row, before the profile starts.
  await page.evaluate(
    async ({ wide }) => {
      const root = document.getElementById("root")!;
      root.style.width = `${wide}px`;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      for (let frame = 0; frame < 10; frame += 1) await new Promise(requestAnimationFrame);
      scroller.scrollTop = scroller.scrollHeight;
      for (let frame = 0; frame < 30; frame += 1) await new Promise(requestAnimationFrame);
    },
    { wide: WIDE },
  );

  if (MODE === "step") {
    // Untimed first: the steps' frame cost with no profiler sampling the main thread.
    const runSteps = (widths: readonly number[] = STEP_WIDTHS) =>
      page.evaluate(
        async ({ widths, count, rest }) => {
          const root = document.getElementById("root")!;
          const frames: number[] = [];
          for (let index = 0; index < count; index += 1) {
            await new Promise<void>((done) =>
              requestAnimationFrame(() => {
                const started = performance.now();
                root.style.width = `${widths[index % widths.length]}px`;
                const channel = new MessageChannel();
                channel.port1.onmessage = () => {
                  frames.push(performance.now() - started);
                  done();
                };
                // Runs once this frame's rendering step (style, layout, the observers, paint) ended.
                channel.port2.postMessage(0);
              }),
            );
            await new Promise((done) => setTimeout(done, rest));
          }
          return frames;
        },
        { widths: [...widths], count: STEP_COUNT, rest: STEP_REST_MS },
      );
    const stepAt = (values: number[], p: number) => {
      const sorted = [...values].sort((a, b) => a - b);
      return Math.round((sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0) * 10) / 10;
    };
    // Warm: the first steps at each width build what later steps reuse.
    await runSteps();
    const untimed = await runSteps();
    console.log(
      `resize-step steps=${untimed.length} frame p50/p95/max=${stepAt(untimed, 0.5)}/${stepAt(untimed, 0.95)}/${stepAt(untimed, 1)} ms (no profiler)`,
    );
    await cdp.send("Profiler.start");
    const profiled = await runSteps();
      const { profile } = (await cdp.send("Profiler.stop")) as unknown as { profile: Profile };
      console.log(`resize-step frame p50=${stepAt(profiled, 0.5)} ms (profiled)`);
      printProfile(profile, STEP_COUNT);
    // The floor: the same steps writing the width the chat already has, so nothing resizes. What
    // the profile samples then is the bench's own rhythm (its timers and frames), not the chat's.
    const rest = STEP_WIDTHS[STEP_WIDTHS.length - 1];
    await page.evaluate((width) => (document.getElementById("root")!.style.width = `${width}px`), rest);
    await new Promise((done) => setTimeout(done, STEP_REST_MS));
    await cdp.send("Profiler.start");
    await runSteps([rest]);
    const { profile: floor } = (await cdp.send("Profiler.stop")) as unknown as { profile: Profile };
    console.log("");
    console.log("floor (no width change):");
    printProfile(floor, STEP_COUNT, 8);
  } else {
    await cdp.send("Profiler.start");
      const work = await page.evaluate(
        async ({ wide, narrow, steps }) => {
          const root = document.getElementById("root")!;
          const widths = [
            ...Array.from({ length: steps }, (_, i) => wide - ((wide - narrow) * (i + 1)) / steps),
            ...Array.from({ length: steps }, (_, i) => narrow + ((wide - narrow) * (i + 1)) / steps),
          ].map(Math.round);
          const step = window as unknown as { __stepFoldStream: () => void };
          const frames: number[] = [];
          // Whether the drag's rows were in normal flow this frame (VirtualTranscript `startFlow`, class
          // `acpmux-thread--flow`): in flow the browser rewraps them with no React pass and no height
          // read, and the row observer returns early. A drag that never enters it pays a synchronous
          // render and measure per frame instead, so this counts the frames that got the fast path.
          let flowed = 0;
          await new Promise<void>((done) => {
            let index = 0;
            const tick = () => {
              if (index >= widths.length) return done();
              const started = performance.now();
              root.style.width = `${widths[index]}px`;
              index += 1;
              step.__stepFoldStream();
              const channel = new MessageChannel();
              channel.port1.onmessage = () => {
                frames.push(performance.now() - started);
                if (document.querySelector(".acpmux-thread--flow")) flowed += 1;
              };
              channel.port2.postMessage(0);
              requestAnimationFrame(tick);
            };
            requestAnimationFrame(tick);
          });
          return { frames, flowed };
        },
        { wide: WIDE, narrow: NARROW, steps: STEPS },
      );
    const { profile } = (await cdp.send("Profiler.stop")) as unknown as { profile: Profile };

    const sorted = [...work.frames].sort((a, b) => a - b);
    const at = (p: number) =>
      Math.round((sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * p))] ?? 0) * 10) / 10;
    console.log(
      `resize-profile frames=${work.frames.length} frame work p50/p95/max=${at(0.5)}/${at(0.95)}/${at(1)} ms` +
        ` rows-in-flow frames=${work.flowed}/${work.frames.length}`,
    );

    printProfile(profile, 0);
  }
  await page.close().catch(() => {});
} finally {
  await browser.close();
  await served.close();
}
