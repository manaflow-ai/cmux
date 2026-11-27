// cmux-web-test-timeout: 240
// The files panel motion never shows a blank strip (files-panel-motion.ts), in headless Chromium
// and WebKit on the latency harness's diff page: at every step of an open, a close and a toggle in
// the middle of either slide, each point of the content's width is covered by the diff column, the
// panel or the curtain, and the diff column changes width once per slide, two frames after the
// click, before the panel has moved: nothing jumps when a slide ends.
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
import { stopDevServer } from "./support/devServer";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmDevServer } from "./support/warmDevServer";

await requireBrowserLane("files-panel-coverage.test.ts", async () => {
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
      // With CI set the banner is colored, with an escape between the host and the port.
      const onData = (chunk: Buffer) =>
        String(chunk)
          // oxlint-disable-next-line no-control-regex -- strips ANSI color escapes
          .replace(/\x1b\[[0-9;]*m/g, "")
          .includes(`127.0.0.1:${port}`)
          ? resolve()
          : undefined;
      server!.stdout!.on("data", onData);
      server!.stderr!.on("data", onData);
      server!.on("exit", (code) => reject(new Error(`dev server exited ${code}`)));
    });
    await warmDevServer(base, "/test/latency/diff.html");
  }, 240_000);

  afterAll(() => {
    stopDevServer(server);
  });

  interface Step {
    /** The widest uncovered strip at this step, px. */
    gap: number;
    viewerRight: number;
    motion: string | undefined;
    /** Which slide the step belongs to: 0, or 1 after a reverse. */
    slide: number;
    /** The curtain shows over a diff that already reaches the content's right edge. */
    curtainOverFullDiff: boolean;
  }

  interface Scenario {
    name: string;
    /**
     * Toggle again at this fraction of the slide (a reverse), "before-flip" right after the click
     * (before the diff takes its new width), or null.
     */
    reverseAt: number | "before-flip" | null;
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
    let slideIndex = 0;
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
      const fullDiff = viewer.right >= content.right - 1;
      steps.push({
        gap,
        viewerRight: Math.round(viewer.right),
        motion: panel.dataset.filesMotion,
        slide: slideIndex,
        curtainOverFullDiff: fullDiff && cover != null && cover.width > 1,
      });
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
    const toggleAndCatch = (waitForFlip = true) =>
      new Promise<Animation[]>((resolve, reject) => {
        const before = panel.dataset.filesMotionTarget;
        const observer = new MutationObserver(() => {
          if (panel.dataset.filesMotionTarget === before) return;
          observer.disconnect();
          const caught = slide();
          if (caught.length === 0) {
            reject(new Error(`${scenario.name}: no slide started`));
            return;
          }
          if (!waitForFlip) {
            resolve(caught);
            return;
          }
          // Two frames with the slide held at its start: the diff takes its new width in them (and
          // an open starts its curtain then, so collect the slide's animations again).
          requestAnimationFrame(() => requestAnimationFrame(() => resolve(slide())));
        });
        observer.observe(panel, { attributes: true, attributeFilter: ["data-files-motion-target"] });
        toggle.click();
      });
    const stepThrough = (animations: Animation[]) => {
      for (let step = 0; step <= STEPS; step += 1) {
        seek(animations, step / STEPS);
        sample();
      }
    };
    const beforeFlip = scenario.reverseAt === "before-flip";
    return toggleAndCatch(!beforeFlip).then(async (first) => {
      let animations = first;
      if (beforeFlip) {
        // Toggled again in the same task as the click: the first slide's flip must never land.
        slideIndex = 1;
        animations = await toggleAndCatch();
        stepThrough(animations);
      }
      for (let step = 0; !beforeFlip && step <= STEPS; step += 1) {
        const fraction = step / STEPS;
        seek(animations, fraction);
        sample();
        if (typeof scenario.reverseAt === "number" && fraction >= scenario.reverseAt) {
          // The reverse starts from where the paused slide is now.
          slideIndex = 1;
          animations = await toggleAndCatch();
          stepThrough(animations);
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
            { name: "open, reversed before the flip", reverseAt: "before-flip", ends: "true" },
            { name: "open again", reverseAt: null, ends: "false" },
            { name: "close, reversed before the flip", reverseAt: "before-flip", ends: "false" },
          ];
          for (const scenario of scenarios) {
            const steps = await page.evaluate(runScenario, scenario);
            expect(steps.length).toBeGreaterThan(24);
            const worst = Math.max(...steps.map((step) => step.gap));
            expect({ scenario: scenario.name, worst: worst <= 1 ? 0 : worst }).toEqual({
              scenario: scenario.name,
              worst: 0,
            });
            // The diff column changes width once per slide, before that slide's first step: within a
            // slide, and from the last slide to the end, the width never changes.
            for (const slide of new Set(steps.map((step) => step.slide))) {
              const widths = [...new Set(steps.filter((step) => step.slide === slide).map((step) => step.viewerRight))];
              expect({ scenario: scenario.name, slide, widths: widths.length }).toEqual({
                scenario: scenario.name,
                slide,
                widths: 1,
              });
            }
            // The curtain never draws over a diff that already reaches the right edge.
            expect({ scenario: scenario.name, over: steps.filter((step) => step.curtainOverFullDiff).length }).toEqual({
              scenario: scenario.name,
              over: 0,
            });
            expect(steps.at(-1)!.motion).toBeUndefined();
            expect(await page.evaluate(() => document.body.dataset.filesHidden)).toBe(scenario.ends);
          }
        } finally {
          await browser.close();
        }
      });

      run("turning animation speed off mid-slide cancels the Web Animations and settles the panel", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
          await page.goto(`${base}/test/latency/diff.html`);
          await page.waitForFunction(() => document.body.dataset.streamFileCount === "240", undefined, {
            timeout: 30_000,
          });
          const state = await page.evaluate(async () => {
            const panel = document.querySelector<HTMLElement>("#files-sidebar")!;
            const toggle = document.querySelector<HTMLButtonElement>("#files-toggle")!;
            const before = panel.dataset.filesMotionTarget;
            const changed = new Promise<void>((resolve) => {
              const observer = new MutationObserver(() => {
                if (panel.dataset.filesMotionTarget === before) return;
                observer.disconnect();
                resolve();
              });
              observer.observe(panel, { attributes: true, attributeFilter: ["data-files-motion-target"] });
            });
            toggle.click();
            await changed;
            const started = panel.getAnimations().length;
            document.documentElement.dataset.agentMotion = "off";
            await new Promise((resolve) => setTimeout(resolve, 0));
            return {
              started,
              remaining: panel.getAnimations().length,
              hidden: document.body.dataset.filesHidden,
              motion: panel.dataset.filesMotion,
              target: panel.dataset.filesMotionTarget,
            };
          });
          expect(state.started).toBeGreaterThan(0);
          expect(state.remaining).toBe(0);
          expect(state.hidden).toBe("true");
          expect(state.motion).toBeUndefined();
          expect(state.target).toBeUndefined();
        } finally {
          await browser.close();
        }
      });
    },
  );
});
