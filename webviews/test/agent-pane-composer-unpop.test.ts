// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
// Leo, 2026-11-22: "unsending a message that didnt already get sent should have proper animations
// too, i think. an "un-pop"?" Every variant of the gallery's agent-pane.composer-unpop (one per arm of
// the `composer-unpop` experiment) hits the x on a prompt queued behind a running turn and samples
// every frame: the un-pop is one phase, the restored text never moves once drawn, the rows above
// never turn back, and no frame draws the queued row and the restored text both. `instant` (today's)
// is the control: its numbers are the before, logged, not failed. With FAST_CHECKS_OUT (cmux-ci) or
// CMUX_UNPOP_CAPTURE_DIR each arm leaves a clip (Playwright recordVideo), its end screenshot and its
// numbers there.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-composer-unpop.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-composer-unpop.test.ts", async () => {
  const ENTRY = "agent-pane.composer-unpop";
  const ARMS = ["instant", "fly", "slide", "pop"] as const;
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-composer-unpop: skipping (run `bunx playwright install chromium`)");
    describe.skip("un-pop", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const out = process.env.CMUX_UNPOP_CAPTURE_DIR ?? process.env.FAST_CHECKS_OUT;
  const captures = out ? path.join(out, "composer-unpop") : undefined;
  if (captures) await mkdir(captures, { recursive: true });
  const numbers: Record<string, unknown> = {};
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
    for (let attempt = 1; ; attempt += 1)
      try {
        await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "instant" } });
        break;
      } catch (error) {
        if (attempt >= 3) throw error;
      }
  });
  afterAll(async () => {
    if (captures) await writeFile(path.join(captures, "numbers.json"), JSON.stringify(numbers, null, 2));
    await browser?.close();
    await vite?.close();
  });

  for (const arm of ARMS)
    test(`${arm}: ${arm === "instant" ? "today's take-back, recorded" : "the un-pop is one motion with no double"}`, async () => {
      const size = { width: 1000, height: 800 };
      const context = await browser.newContext({
        viewport: size,
        ...(captures ? { recordVideo: { dir: captures, size } } : {}),
      });
      const page = await context.newPage();
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: arm, width: 900 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
          timeout: 180_000,
        });
        const result = await page.evaluate(() => ({
          report: document.documentElement.dataset.unpopReport ?? null,
          play: JSON.stringify((window as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? null).slice(
            0,
            2000,
          ),
          status: (window as { cmuxGalleryPlayReport?: { status?: string } }).cmuxGalleryPlayReport?.status ?? null,
        }));
        const report = result.report ? JSON.parse(result.report) : null;
        numbers[arm] = report;
        console.log(`${arm}: ${result.report}; play ${result.status}`);
        if (captures) await page.screenshot({ path: path.join(captures, `${arm}-end.png`) });
        expect(report).not.toBeNull();
        if (arm === "instant") return;
        expect({
          arm,
          phases: report.phases,
          textMoves: report.textMoves,
          aboveTurns: report.aboveTurns,
          doubles: report.doubles,
        }).toEqual({ arm, phases: 1, textMoves: 0, aboveTurns: false, doubles: 0 });
        expect(result.status === "fail" ? result.play : "").toBe("");
      } finally {
        const video = page.video();
        await context.close();
        if (captures && video) await rename(await video.path(), path.join(captures, `${arm}.webm`)).catch(() => {});
      }
    });
});
