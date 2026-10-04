// The files panel motion never shows a blank strip (files-panel-motion.ts), in headless Chromium
// and WebKit on the latency harness's diff page: at every step of an open, a close and a toggle in
// the middle of either slide, each point of the content's width is covered by the diff column, the
// panel or the curtain, and the diff column changes width only when a slide ends.
//
// Deterministic: the test pauses the slide's animations and seeks them through 24 steps with
// `currentTime`, toggles again at an exact step for the reverses, then finishes them. Nothing
// depends on wall-clock frames, so a loaded machine cannot change what is checked. (The first
// version sampled animation frames in real time and reversed after a 50 ms wait; under load the
// samples and the reverse point moved, and it failed once in a full run.) Engines that are not
// installed are skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type BrowserType } from "playwright";

setDefaultTimeout(120_000);
const webviews = path.resolve(import.meta.dir, "..");
const engines: Array<[string, BrowserType]> = [
  ["chromium", chromium],
  ["webkit", webkit],
];
const installed: Array<[string, BrowserType]> = [];
for (const engine of engines) {
  try {
    const browser = await engine[1].launch({ headless: true });
    await browser.close();
    installed.push(engine);
  } catch {
    // Not installed here.
  }
}

let server: ChildProcess | null = null;
let base = "";

beforeAll(async () => {
  if (installed.length === 0) return;
  const port = await new Promise<number>((resolve) => {
    const probe = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as net.AddressInfo;
      probe.close(() => resolve(port));
    });
  });
  server = spawn(path.join(webviews, "node_modules/.bin/vp"), ["dev", "--port", String(port), "--strictPort"], {
    cwd: webviews,
    stdio: ["ignore", "pipe", "pipe"],
  });
  base = `http://127.0.0.1:${port}`;
  await new Promise<void>((resolve, reject) => {
    const onData = (chunk: Buffer) => (String(chunk).includes(`127.0.0.1:${port}`) ? resolve() : undefined);
    server!.stdout!.on("data", onData);
    server!.stderr!.on("data", onData);
    server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
  });
}, 60_000);

afterAll(() => {
  server?.kill();
});

interface Step {
  /** The widest uncovered strip at this step, px. */
  gap: number;
  viewerRight: number;
  motion: string | undefined;
}

interface Scenario {
  name: string;
  /** Toggle again at this fraction of the slide (a reverse), or null. */
  reverseAt: number | null;
  /** `data-files-hidden` when the scenario ends. */
  ends: "true" | "false";
}

/**
 * Toggles the panel and steps its slide (and a reverse) by seeking the paused animations, then
 * finishes it. Returns every step, including the one after the slide ends.
 */
function runScenario(scenario: Scenario): Promise<Step[]> {
  const STEPS = 24;
  const panel = document.querySelector<HTMLElement>("#files-sidebar")!;
  const curtain = document.querySelector<HTMLElement>("#files-motion-curtain");
  const toggle = document.querySelector<HTMLButtonElement>("#files-toggle")!;
  const steps: Step[] = [];
  const sample = () => {
    const content = document.querySelector("#content")!.getBoundingClientRect();
    const viewer = document.querySelector("#viewer")!.getBoundingClientRect();
    const box = panel.getBoundingClientRect();
    const cover = curtain?.getBoundingClientRect();
    const panelShown = getComputedStyle(panel).visibility !== "hidden";
    // Covered from the content's left edge: the diff column, then the curtain, then the panel.
    let covered = viewer.right;
    if (cover && cover.width > 0 && cover.left <= covered + 1) covered = Math.max(covered, cover.right);
    const gap = panelShown
      ? Math.max(0, Math.min(box.left, content.right) - covered)
      : Math.max(0, content.right - covered);
    steps.push({ gap, viewerRight: Math.round(viewer.right), motion: panel.dataset.filesMotion });
  };
  // The slide's animations (panel and curtain), paused so the test owns their clock.
  const slide = () => {
    const animations = [...panel.getAnimations(), ...(curtain?.getAnimations() ?? [])];
    for (const animation of animations) animation.pause();
    return animations;
  };
  const seek = (animations: Animation[], fraction: number) => {
    for (const animation of animations) {
      const duration = Number(animation.effect?.getTiming().duration ?? 0);
      animation.currentTime = duration * fraction;
    }
  };
  // A toggle's slide starts in React's commit, after click() returns. The panel's motion target
  // changes in that commit; a MutationObserver callback runs in the microtask right after it,
  // before any animation frame, so the slide is paused before it has moved or could end.
  const toggleAndCatch = () =>
    new Promise<Animation[]>((resolve, reject) => {
      const before = panel.dataset.filesMotionTarget;
      const observer = new MutationObserver(() => {
        if (panel.dataset.filesMotionTarget === before) return;
        observer.disconnect();
        const caught = slide();
        if (caught.length === 0) reject(new Error(`${scenario.name}: no slide started`));
        else resolve(caught);
      });
      observer.observe(panel, { attributes: true, attributeFilter: ["data-files-motion-target"] });
      toggle.click();
    });
  return toggleAndCatch().then(async (first) => {
    let animations = first;
    for (let step = 0; step <= STEPS; step += 1) {
      const fraction = step / STEPS;
      seek(animations, fraction);
      sample();
      if (scenario.reverseAt != null && fraction >= scenario.reverseAt) {
        // The reverse starts from where the paused slide is now.
        animations = await toggleAndCatch();
        for (let back = 0; back <= STEPS; back += 1) {
          seek(animations, back / STEPS);
          sample();
        }
        break;
      }
    }
    // End the slide: its `finished` handler flips the layout (the one reflow) and stops the motion.
    const ended = Promise.all(animations.map((animation) => animation.finished));
    for (const animation of animations) animation.finish();
    await ended;
    await Promise.resolve();
    sample();
    return steps;
  });
}

describe.each(installed.length ? installed : [["none", chromium] as [string, BrowserType]])(
  "files panel motion in %s",
  (_name, engine) => {
    const run = installed.length ? test : test.skip;
    run("close, open and both mid-slide reverses: no blank strip at any step, one reflow per slide", async () => {
      const browser = await engine.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
        await page.goto(`${base}/test/latency/diff.html`);
        await page.waitForFunction(() => document.body.dataset.streamFileCount === "240", undefined, {
          timeout: 30_000,
        });
        expect(await page.evaluate(() => document.body.dataset.filesHidden)).toBe("false");
        const scenarios: Scenario[] = [
          { name: "close", reverseAt: null, ends: "true" },
          { name: "open", reverseAt: null, ends: "false" },
          { name: "close, reversed half-way", reverseAt: 0.5, ends: "false" },
          { name: "close again", reverseAt: null, ends: "true" },
          { name: "open, reversed half-way", reverseAt: 0.5, ends: "true" },
        ];
        for (const scenario of scenarios) {
          const steps = await page.evaluate(runScenario, scenario);
          expect(steps.length).toBeGreaterThan(24);
          const worst = Math.max(...steps.map((step) => step.gap));
          expect({ scenario: scenario.name, worst: worst <= 1 ? 0 : worst }).toEqual({
            scenario: scenario.name,
            worst: 0,
          });
          // The diff column keeps its width through the slide and changes at most once, at the end.
          const widths = steps.map((step) => step.viewerRight);
          const changes = widths.filter((width, index) => index > 0 && width !== widths[index - 1]).length;
          expect({ scenario: scenario.name, changes }).toEqual({
            scenario: scenario.name,
            changes: Math.min(changes, 1),
          });
          expect(steps.slice(0, -1).every((step) => step.viewerRight === widths[0])).toBe(true);
          expect(steps.at(-1)!.motion).toBeUndefined();
          expect(await page.evaluate(() => document.body.dataset.filesHidden)).toBe(scenario.ends);
        }
      } finally {
        await browser.close();
      }
    });
  },
);
