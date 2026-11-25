// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
// Leo, 2026-11-22, after the send pop: "actually, i think the send pop and whatever... well it's made me
// aware of another situation, which is that the chat transcript above doesn't quite smoothly account
// for things." Each variant of the gallery's agent-pane.send-rise turns the pop on, sends with one rise
// arm (composerStates.css SEND-RISE) and samples every frame. With the pop's rise, the rows above move
// no more than 15% of their travel in any frame and come to rest with the bubble on its clock; `none`
// (before) moves more than that in some frame and rests early, which shows the probe sees what it fixes.
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
  const STEP = 0.15;
  /// The rows above rest no sooner than this (ms into the sample) on the pop's 475 ms clock.
  const RISE_REST_MS = 400;
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
          // A send now takes the sent prompt to the top (#47801), so the rows above travel most of a
          // viewport: a smooth rise spreads it, at most STEP of it in any frame; `none` moves it whole.
          const smooth = result.jump <= result.travel * STEP;
          // `none` (before): the send step's own ~200 ms motion moves more than STEP of the way in some
          // frame (25-36% on feat-cmux-next after #52754/#53483; a 644 px one-frame jump before them).
          if (arm === "none") expect(result.jump).toBeGreaterThan(result.travel * STEP);
          else {
            expect({ variant, jump: smooth, frames: smooth ? "" : result.frames }).toEqual({
              variant,
              jump: true,
              frames: "",
            });
            // The pop's arms rest with the bubble, within two 60 Hz frames of it.
            if (arm !== "quick") expect(Math.abs(result.prevRest - result.sentRest)).toBeLessThanOrEqual(40);
            // And on the pop's clock (475 ms from the send's first frame, ~67 ms into the sample): a
            // tall prompt's rows rested at 283 ms when a pass's move fell off the rise (followChase
            // `joinsRise`) and the composer's collapse played on the fold's 180 ms (motionTransaction).
            if (arm !== "quick") expect(result.prevRest).toBeGreaterThanOrEqual(RISE_REST_MS);
          }
        } finally {
          await page.close();
        }
      });
    }
});
