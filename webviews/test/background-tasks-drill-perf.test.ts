// cmux-web-test-timeout: 300
//
// Leo, 2026-10-29: "i also like the way it just loads in the subagent stuff instantly :(" (Claude
// Desktop's Background tasks panel; ours did not). This measures click to first painted content when
// a subagent's transcript opens, in the gallery's agent pane with three agents and 50 rows of
// transcript (agent-pane.background-tasks), with real Chromium:
//
//   - before: the tray's subagent line (SubagentTray.tsx), which shows the subagent's view in the
//     chat (App.tsx `showSubagent`; in the app it opens a pane of its own first, which this page has
//     no host for, so the in-chat view is the fastest the old path gets);
//   - after: the agent's line in the Background tasks panel, which draws its transcript in place
//     from the snapshot (SubagentTranscript.tsx).
//
// Each sample clicks in the page, lets React's microtask commit run, and stops the clock once the
// content is in the DOM, counting the frames that passed without it: zero frames means the content
// is committed before the next frame, so it paints on the click's own frame. The
// panel must have its content in under one frame (FRAME_MS) at the median and on every sample's
// first frame.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("background-tasks-drill-perf.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("background-tasks-drill-perf: skipping (run `bunx playwright install chromium`)");
    describe.skip("background tasks drill perf", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.background-tasks";
  /// One frame at 60 Hz: the panel's open must paint inside it.
  const FRAME_MS = 16.7;
  const SAMPLES = 15;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (variant: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 1280, height: 800 } });
    for (;;) {
      try {
        await page.goto(url(variant));
        await page.waitForFunction(
          () => {
            const root = document.documentElement.dataset;
            return root.galleryReady === "error" || (root.galleryReady === "1" && Boolean(root.galleryPlay));
          },
          undefined,
          { timeout: 90_000 },
        );
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    return page;
  };

  /// Clicks `click` and times to the frame after `shown` is in the DOM; `reset` puts it back.
  const sample = (page: Page, click: string, shown: string, reset: string) =>
    page.evaluate(
      async ({ click, shown, reset, samples }) => {
        const frame = () => new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
        const times: number[] = [];
        const frames: number[] = [];
        let emptyOnFrame = 0;
        for (let index = 0; index < samples; index += 1) {
          const button = document.querySelector<HTMLElement>(click);
          if (!button) throw new Error(`no ${click}`);
          await frame();
          const start = performance.now();
          button.click();
          // React commits a click's update in a microtask after the handler returns, before the
          // frame paints: let those run before looking, so batching is not counted as a frame.
          for (let tick = 0; tick < 8 && !document.querySelector(shown); tick += 1) await Promise.resolve();
          // Frames that passed with the content still missing: 0 is the click's own frame.
          let waited = 0;
          while (!document.querySelector(shown) && waited < 600) {
            waited += 1;
            await frame();
          }
          if (waited > 0) emptyOnFrame += 1;
          times.push(performance.now() - start);
          frames.push(waited);
          document.querySelector<HTMLElement>(reset)?.click();
          await frame();
          await frame();
        }
        times.sort((a, b) => a - b);
        frames.sort((a, b) => a - b);
        return {
          median: times[Math.floor(times.length / 2)]!,
          max: times.at(-1)!,
          frames: frames[Math.floor(frames.length / 2)]!,
          emptyOnFrame,
        };
      },
      { click, shown, reset, samples: SAMPLES },
    );

  test("the panel paints a subagent's transcript on the click's frame; the tray's view is the baseline", async () => {
    const before = await open("closed");
    const old = await sample(
      before,
      ".acpmux-running-tray .acpmux-agent-line__button:not(:disabled)",
      ".cv-subagent-of",
      ".cv-subagent-of__pill",
    );
    await before.close();
    const page = await open("alone");
    const panel = await sample(
      page,
      ".acpmux-bg__group .acpmux-bg__name:not(:disabled)",
      ".acpmux-bg__transcript [data-row-id]",
      ".acpmux-bg__head button",
    );
    await page.close();
    console.log(
      `background-tasks-drill-perf: before (tray → in-chat view) median ${old.median.toFixed(1)} ms, max ${old.max.toFixed(1)} ms; ` +
        `(${old.frames} empty frames at the median, ${old.emptyOnFrame} of ${SAMPLES} empty on the click's frame); ` +
        `after (panel → transcript) median ${panel.median.toFixed(1)} ms, max ${panel.max.toFixed(1)} ms ` +
        `(${panel.frames} empty frames at the median, ${panel.emptyOnFrame} of ${SAMPLES} empty on the click's frame)`,
    );
    expect(panel.emptyOnFrame).toBe(0);
    expect(panel.median).toBeLessThan(FRAME_MS);
  });
});
