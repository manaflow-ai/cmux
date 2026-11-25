// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
// Detector send-slot-transitions-complete, its browser half (design/composer-send-slot.md). Leo,
// 2026-11-22: "idle to send to stop to whatever we need those to be like... known." Every variant
// of gallery agent-pane.composer-send-slot-states plays idle -> send-ready -> sending -> stop ->
// stopping -> idle in Claude's look and Codex's, reading every frame: the button's box never moves
// or resizes, and each glyph change runs exactly the morphs the table names (one, or none for an
// instant row), never two at once. The table's own completeness is the unit half,
// src/agent-session/acpmux/composer/sendSlotTransitions.test.ts.
//
// With CMUX_SEND_SLOT_CAPTURE_DIR (or $FAST_CHECKS_OUT on CI) set it writes each variant's clip
// (.webm) and its filmstrip (.png) there, for the coordinator's choice between them.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/send-slot-states.browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, rename } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { SLOT_VARIANT_IDS } from "../src/agent-session/acpmux/composer/sendSlotVariants";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("send-slot-states.browser.test.ts", async () => {
  const ENTRY = "agent-pane.composer-send-slot-states";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("send-slot-states: skipping (run `bunx playwright install chromium`)");
    describe.skip("the send slot's states", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const captureRoot = process.env.CMUX_SEND_SLOT_CAPTURE_DIR ?? process.env.FAST_CHECKS_OUT;
  const captureDir = captureRoot ? path.join(captureRoot, "send-slot-states") : undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    if (captureDir) await mkdir(captureDir, { recursive: true });
    // A cold dev server can fail the first dynamic import while it optimizes dependencies: warm again.
    for (let attempt = 1; ; attempt += 1)
      try {
        await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "scale" } });
        break;
      } catch (error) {
        if (attempt >= 3) throw error;
      }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of SLOT_VARIANT_IDS)
    test(`${variant}: one box, and each glyph change runs the table's morphs`, async () => {
      const context = await browser.newContext({
        viewport: { width: 760, height: 620 },
        deviceScaleFactor: 2,
        ...(captureDir ? { recordVideo: { dir: captureDir, size: { width: 760, height: 620 } } } : {}),
      });
      const page = await context.newPage();
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 640 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
          timeout: 180_000,
        });
        const result = await page.evaluate(() => ({
          ready: document.documentElement.dataset.galleryReady ?? null,
          report: document.documentElement.dataset.sendSlotReport ?? null,
          play: JSON.stringify((window as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? null).slice(
            0,
            2000,
          ),
        }));
        console.log(`${variant}: ${result.report}`);
        const report = JSON.parse(result.report ?? "null") as {
          problems: string[];
          swaps: Array<{ expected: number; morphs: number }>;
        } | null;
        expect({ variant, ready: result.ready, reported: report !== null }).toEqual({
          variant,
          ready: "1",
          reported: true,
        });
        expect({ variant, problems: report!.problems }).toEqual({ variant, problems: [] });
        // The journey morphs somewhere: a play that sampled nothing passes nothing.
        expect(report!.swaps.some((swap) => swap.expected === 1 && swap.morphs === 1)).toBe(true);
        if (captureDir) await page.screenshot({ path: path.join(captureDir, `${variant}.png`), fullPage: true });
      } finally {
        await page.close();
        await context.close();
        const video = page.video();
        if (captureDir && video) await rename(await video.path(), path.join(captureDir, `${variant}.webm`));
      }
    });
});
