// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
// Leo, 2026-11-22, after the send pop: "actually, i think the send pop and whatever... well it's made me
// aware of another situation, which is that the chat transcript above doesn't quite smoothly account
// for things." Each variant of the gallery's agent-pane.send-rise turns the pop on, sends with one rise
// arm (composerStates.css SEND-RISE) and samples every frame. With the pop's rise, the rows above move
// no more than a line in any frame and come to rest with the bubble; `none` (before) still jumps the
// whole room in one frame, which shows the probe sees the jump it fixes.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-rise.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-send-rise.test.ts", async () => {
  const ENTRY = "agent-pane.send-rise";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-rise: skipping (run `bunx playwright install chromium`)");
    describe.skip("the transcript rises with the send pop", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
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
    // A cold dev server can fail the first dynamic import while it optimizes dependencies: warm again.
    for (let attempt = 1; ; attempt += 1)
      try {
        await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "pop-1-line-idle" } });
        break;
      } catch (error) {
        if (attempt >= 3) throw error;
      }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The chat's line (px) in the mock pane: no frame of a smooth rise moves the rows above more than it.
  const LINE = 24;
  for (const arm of ["pop", "settle", "quick", "none"])
    for (const shape of ["1-line-idle", "3-lines-idle", "5-lines-idle"]) {
      const variant = `${arm}-${shape}`;
      test(`${variant}: the rows above ${arm === "none" ? "jump (before)" : "rise with the bubble"}`, async () => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 800 } });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900 })}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
            timeout: 180_000,
          });
          const result = await page.evaluate(() => {
            const data = document.documentElement.dataset;
            return {
              jump: Number(data.risePrevJump),
              travel: Number(data.risePrevTravel),
              prevRest: Number(data.risePrevRest),
              sentRest: Number(data.riseSentRest),
              frames: (data.riseFrames ?? "").slice(0, 3000),
            };
          });
          console.log(
            `${variant}: rows above travel ${result.travel}px, largest frame ${result.jump}px, rest ${result.prevRest} ms (bubble ${result.sentRest} ms)`,
          );
          expect(result.travel).toBeGreaterThan(LINE);
          if (arm === "none") expect(result.jump).toBeGreaterThan(LINE);
          else {
            expect({ variant, jump: result.jump <= LINE, frames: result.jump <= LINE ? "" : result.frames }).toEqual({
              variant,
              jump: true,
              frames: "",
            });
            // The pop's arms rest with the bubble, within two 60 Hz frames of it.
            if (arm !== "quick") expect(Math.abs(result.prevRest - result.sentRest)).toBeLessThanOrEqual(40);
          }
        } finally {
          await page.close();
        }
      });
    }
});
