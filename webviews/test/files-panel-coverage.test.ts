// The files panel motion never shows a blank strip (files-panel-motion.ts), in headless Chromium
// and WebKit on the latency harness's diff page: at every animation frame of an open, a close and
// a toggle in the middle of either slide, each point of the content's width is covered by the
// diff column, the panel or the curtain. The diff column changes width only when a slide ends.
// Engines that are not installed are skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import path from "node:path";
import { chromium, webkit, type BrowserType, type Page } from "playwright";

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

interface Frame {
  /** The widest uncovered strip in this frame, px. */
  gap: number;
  viewerRight: number;
  hidden: string | undefined;
  motion: string | undefined;
}

/** Records every animation frame until stopped. */
async function startSampling(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as { __frames: Frame[]; __sampling: boolean };
    w.__frames = [];
    w.__sampling = true;
    const sample = () => {
      if (!w.__sampling) return;
      const content = document.querySelector("#content")!.getBoundingClientRect();
      const viewer = document.querySelector("#viewer")!.getBoundingClientRect();
      const panelElement = document.querySelector<HTMLElement>("#files-sidebar")!;
      const panel = panelElement.getBoundingClientRect();
      const curtain = document.querySelector("#files-motion-curtain")?.getBoundingClientRect();
      const panelShown = getComputedStyle(panelElement).visibility !== "hidden";
      // Covered from the content's left edge: the diff column, then the curtain, then the panel.
      let covered = viewer.right;
      if (curtain && curtain.width > 0 && curtain.left <= covered + 1) covered = Math.max(covered, curtain.right);
      const gap = panelShown
        ? Math.max(0, Math.min(panel.left, content.right) - covered)
        : Math.max(0, content.right - covered);
      w.__frames.push({
        gap,
        viewerRight: Math.round(viewer.right),
        hidden: document.body.dataset.filesHidden,
        motion: panelElement.dataset.filesMotion,
      });
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  });
}

async function stopSampling(page: Page): Promise<Frame[]> {
  return page.evaluate(() => {
    const w = window as unknown as { __frames: Frame[]; __sampling: boolean };
    w.__sampling = false;
    return w.__frames;
  });
}

const settled = (page: Page) =>
  page.waitForFunction(() => !document.querySelector<HTMLElement>("#files-sidebar")?.dataset.filesMotion);

describe.each(installed.length ? installed : [["none", chromium] as [string, BrowserType]])(
  "files panel motion in %s",
  (_name, engine) => {
    const run = installed.length ? test : test.skip;
    run("close, open and both mid-slide reverses: no blank strip at any frame, one reflow per slide", async () => {
      const browser = await engine.launch({ headless: true });
      try {
        const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
        await page.goto(`${base}/test/latency/diff.html`);
        await page.waitForFunction(() => document.body.dataset.streamFileCount === "240", undefined, {
          timeout: 30_000,
        });
        await page.waitForTimeout(500);
        expect(await page.evaluate(() => document.body.dataset.filesHidden)).toBe("false");
        const scenarios: Array<{ name: string; reverseAfterMs: number | null }> = [
          { name: "close", reverseAfterMs: null },
          { name: "open", reverseAfterMs: null },
          { name: "close, reversed mid-slide", reverseAfterMs: 50 },
          { name: "close again", reverseAfterMs: null },
          { name: "open, reversed mid-slide", reverseAfterMs: 50 },
        ];
        for (const scenario of scenarios) {
          await settled(page);
          await startSampling(page);
          await page.click("#files-toggle");
          if (scenario.reverseAfterMs != null) {
            await page.waitForTimeout(scenario.reverseAfterMs);
            await page.click("#files-toggle");
          }
          await settled(page);
          await page.waitForTimeout(100);
          const frames = await stopSampling(page);
          expect(frames.length).toBeGreaterThan(3);
          const worst = Math.max(...frames.map((frame) => frame.gap));
          expect({ scenario: scenario.name, worst: worst <= 1 ? 0 : worst }).toEqual({
            scenario: scenario.name,
            worst: 0,
          });
          // The diff column changes width at most once per scenario, and never while the panel slides.
          const widths = frames.map((frame) => frame.viewerRight);
          const changes = widths.filter((width, index) => index > 0 && width !== widths[index - 1]).length;
          expect(changes).toBeLessThanOrEqual(1);
          const midSlideChange = frames.some(
            (frame, index) => index > 0 && frame.viewerRight !== frames[index - 1].viewerRight && frame.motion,
          );
          expect(midSlideChange).toBe(false);
        }
        // A reversed open ends closed; a reversed close ends open: the panel ends where it started.
        expect(await page.evaluate(() => document.body.dataset.filesHidden)).toBe("true");
      } finally {
        await browser.close();
      }
    });
  },
);
