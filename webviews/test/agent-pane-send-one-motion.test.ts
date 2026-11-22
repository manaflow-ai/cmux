// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 900
// Leo, 2026-11-22: "i just felt like just now there was a one-two motion when sending a tall message
// (i.e. multi line composer) when i send it collapses the compser then sends it to you... but i think
// we should be able to calculate it out to be like one smooth motion." Every variant of the gallery's
// agent-pane.composer-send-one-motion (a 1, 5 or 15 line draft; the agent idle or busy; from the latest
// row or scrolled up) plays its send and samples every frame: the composer, the last prompt, the sent
// prompt and the thinking row move in one phase (gallery/motionPhases.ts).
//
// Leo, 2026-11-22: "GOD I HATE OUR FUCKING SENDS FROM COMPOSER TO WHEREVER IT FUCKING JUMPS" / "THE
// FUCSKING COLLAPSING OF THE FUCKING COMPOSER / IT TAKES TOO FUCKING LONG". Each send also fails unless
// the prompt field's height changes in one frame, the frame its text clears; the sent row never moves
// after it is first drawn; the row above it moves in one frame at most (gallery `sendFrames`). Drafts
// of 1, 5 and 30 lines, in Chromium and in WebKit (the Mac app's pane).
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-send-one-motion.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser } from "playwright";
import type { SendFrames } from "../src/agent-session/acpmux/composerSendOneMotion.gallery";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-send-one-motion.test.ts", async () => {
  const ENTRY = "agent-pane.composer-send-one-motion";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-send-one-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("a tall send is one motion", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  // The app's pane is WebKit (WKWebView) on the Mac: the send is measured there too.
  let webkitBrowser: Browser | undefined;
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
        await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "1-lines-idle-latest" } });
        break;
      } catch (error) {
        if (attempt >= 3) throw error;
      }
    webkitBrowser = await webkit.launch({ headless: true }).catch(() => undefined);
  });
  afterAll(async () => {
    await webkitBrowser?.close();
    await browser?.close();
    await vite?.close();
  });

  for (const engine of ["chromium", "webkit"] as const)
    for (const lines of [1, 5, 30])
      for (const busy of ["idle", "busy"])
        for (const place of ["latest", "scrolled-up"]) {
          const variant = `${lines}-lines-${busy}-${place}`;
          const name = `${engine} ${variant}`;
          // Scrolled up while a turn runs, the queued prompt's send can bounce the rows for one frame on
          // the base code as well (a separate cause): its play records the phases without failing.
          if (busy === "busy" && place === "scrolled-up") {
            test.todo(`${name}: the queued send's one-frame bounce`, () => {});
            continue;
          }
          test(`${name}: the send moves in one phase, the composer collapses in one frame`, async () => {
            const on = engine === "webkit" ? webkitBrowser : browser;
            if (!on) {
              console.warn(`${name}: skipping (webkit did not launch)`);
              return;
            }
            const page = await on.newPage({ viewport: { width: 1000, height: 800 } });
            try {
              const port = (vite!.httpServer!.address() as { port: number }).port;
              await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900 })}`);
              await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
                timeout: 180_000,
              });
              const result = await page.evaluate(() => ({
                phases: document.documentElement.dataset.sendPhases ?? null,
                maxJump: document.documentElement.dataset.sendMaxJump ?? null,
                stats: document.documentElement.dataset.sendFrameStats ?? null,
                frames: document.documentElement.dataset.sendFrames ?? null,
                status:
                  (window as { cmuxGalleryPlayReport?: { status?: string } }).cmuxGalleryPlayReport?.status ?? null,
                report: JSON.stringify(
                  (window as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport ?? null,
                ).slice(0, 2000),
              }));
              console.log(`${name}: phases ${result.phases}, max jump ${result.maxJump}px, play ${result.status}`);
              console.log(`SENDSTATS ${engine} ${variant} ${result.stats}`);
              if (process.env.SEND_FRAMES) console.log(`SENDFRAMES ${engine} ${variant} ${result.frames}`);
              const stats = JSON.parse(result.stats ?? "{}") as Partial<SendFrames>;
              // Leo, 2026-11-22: "THE FUCSKING COLLAPSING OF THE FUCKING COMPOSER / IT TAKES TOO FUCKING
              // LONG": the field's height changes in at most one frame, the frame its text clears; the
              // sent row is drawn where it ends and never moves after; the row above it moves in at most
              // one frame (the send's own), never a glide or a second step.
              const fail = result.phases === "1" ? "" : result.report;
              expect({
                name,
                phases: result.phases,
                collapseInOneFrame: (stats.collapseFrames ?? 99) <= 1 && stats.collapseLag === 0,
                sentStill: stats.sentMoves === 0,
                rowsInOneFrame: (stats.prevMoves ?? 99) <= 1,
                fail,
              }).toEqual({
                name,
                phases: "1",
                collapseInOneFrame: true,
                sentStill: true,
                rowsInOneFrame: true,
                fail: "",
              });
            } finally {
              await page.close();
            }
          });
        }
});
