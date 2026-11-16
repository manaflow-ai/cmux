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
//   bun bench/transcript-resize-profile.bench.ts [rows=100000] [shaping=app] [top=25]
/// <reference types="bun" />
import path from "node:path";
import { chromium } from "./browsers";
import { buildLabel, devRequested, gotoBenchPage, requireProductionReact, serveBenchPage } from "./support/benchPage";

const ROWS = Number(process.argv[2] ?? 100_000);
const SHAPING = process.argv[3] ?? "app";
const TOP = Number(process.argv[4] ?? 25);
/// `--dev` takes the number from a dev server instead of the build, labelled `dev`: React is then
/// its development bundle, whose commit-phase instrumentation was about a third of every frame of
/// this drag (bench/support/benchPage.ts).
const DEV = devRequested();
if (!Number.isInteger(ROWS) || ROWS < 3) throw new Error("usage: [rows>=3] [shaping=scratch|app] [top]");
if (SHAPING !== "scratch" && SHAPING !== "app") throw new Error("shaping must be scratch or app");

const webviews = path.resolve(import.meta.dir, "..");
const WIDE = 900;
const NARROW = 520;
const STEPS = 90;

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

const pagePath = "/test/browser/transcript-fling.html";
const served = await serveBenchPage(pagePath, { dev: DEV });
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
    const ms = byNode.get(node.id);
    if (ms === undefined || ms <= 0) continue;
    total += ms;
    const frame = node.callFrame;
    const file = frame.url.replace(/^https?:\/\/[^/]+/, "").replace(/\?.*$/, "");
    const name = frame.functionName || "(anonymous)";
    const key = file ? `${name} ${file}:${frame.lineNumber + 1}` : name;
    named.set(key, (named.get(key) ?? 0) + ms);
  }
  console.log(`resize-profile sampled ${Math.round(total)} ms of main-thread work over the drag`);
  console.log("");
  console.log(`| self ms | share | function |`);
  console.log(`|---|---|---|`);
  for (const [key, ms] of [...named.entries()].sort((a, b) => b[1] - a[1]).slice(0, TOP))
    console.log(`| ${Math.round(ms)} | ${((ms / total) * 100).toFixed(1)}% | ${key} |`);
  await page.close().catch(() => {});
} finally {
  await browser.close();
  await served.close();
}
