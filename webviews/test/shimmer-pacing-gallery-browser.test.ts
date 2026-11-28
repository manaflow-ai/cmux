// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
//
// The Thinking shimmer's pacing gallery (agent-pane.shimmer-pacing, ShimmerPacing.gallery.tsx; Leo,
// 2026-11-08, asked whether other agent apps' shimmers are better paced than ours), in
// real Chromium on the gallery frame. `current` must stay the shipped sweep (cmux-cadenced-shimmer-*,
// 1 s every 4 s); each candidate runs its own cadence through the same controller, its band and lit
// copy on one duration. A strip of stills per variant (one sweep paused at fixed points) goes to
// $FAST_CHECKS_OUT/shimmer-pacing. CI fails the file when Chromium cannot launch (requireBrowserLane).
import { mkdirSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("shimmer-pacing-gallery-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.shimmer-pacing";
  const WIDTH = 560;
  const HEIGHT = 180;
  const PACES: Record<string, { sweepMs: number; everyMs: number; band: string }> = {
    current: { sweepMs: 1000, everyMs: 4000, band: "cmux-cadenced-shimmer-band" },
    "word-band": { sweepMs: 1400, everyMs: 5000, band: "cmux-pace-shimmer-band" },
    "mid-band": { sweepMs: 1200, everyMs: 4500, band: "cmux-pace-shimmer-band" },
    "letter-band": { sweepMs: 1600, everyMs: 5000, band: "cmux-pace-shimmer-band" },
  };
  /** Points of one sweep the strip shows. */
  const STILLS = [0.1, 0.25, 0.4, 0.55, 0.7, 0.85];
  const out = process.env.FAST_CHECKS_OUT;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "current" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string): Promise<Page> {
    const page = await browser!.newPage({
      viewport: { width: WIDTH, height: HEIGHT },
      deviceScaleFactor: 2,
      reducedMotion: "no-preference",
      colorScheme: "dark",
    });
    const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
    await page.goto(base + galleryFrame(ENTRY, { variant, colorScheme: "dark", width: WIDTH, height: HEIGHT }));
    await page.waitForFunction(
      () => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
      undefined,
      { timeout: 90_000 },
    );
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    await page.locator(".cv-shimmer__band").first().waitFor({ state: "attached" });
    return page;
  }

  describe("shimmer pacing", () => {
    for (const [variant, pace] of Object.entries(PACES))
      test(variant, async () => {
        const page = await open(variant);
        try {
          // The cadence: how long the first band stays active and how far apart two sweeps start.
          // Resolves on the second sweep's start: one whole sweep and one whole rest seen.
          const timing = await page.evaluate(
            () =>
              new Promise<{ on: number[]; off: number[] }>((done) => {
                const band = document.querySelector(".cv-shimmer__band")!;
                const on: number[] = [];
                const off: number[] = [];
                let was = band.classList.contains("is-shimmer-active");
                const observer = new MutationObserver(() => {
                  const now = band.classList.contains("is-shimmer-active");
                  if (now !== was) (now ? on : off).push(performance.now());
                  was = now;
                  if (on.length >= 2 && off.some((at) => at > on[0]!)) {
                    observer.disconnect();
                    done({ on, off });
                  }
                });
                observer.observe(band, { attributes: true, attributeFilter: ["class"] });
              }),
          );
          expect(timing.on.length).toBeGreaterThanOrEqual(2);
          const firstOff = timing.off.find((at) => at > timing.on[0]!)!;
          expect(Math.abs(firstOff - timing.on[0]! - pace.sweepMs)).toBeLessThan(150);
          expect(Math.abs(timing.on[1]! - timing.on[0]! - pace.everyMs)).toBeLessThan(150);

          // During a sweep: every line's band and lit copy run one keyframes pair on the sweep's duration.
          await page.waitForFunction(
            () => document.querySelectorAll(".cv-shimmer__band.is-shimmer-active").length === 3,
          );
          await page.evaluate(() => document.getAnimations().forEach((animation) => animation.pause()));
          const loops = await page.evaluate(() =>
            document
              .getAnimations()
              .map((animation) => ({
                name: (animation as CSSAnimation).animationName,
                duration: Number(animation.effect?.getTiming().duration),
              }))
              .filter((loop) => /shimmer/.test(loop.name)),
          );
          expect(loops.length).toBe(6);
          for (const loop of loops) expect(loop.duration).toBe(pace.sweepMs);
          expect(loops.filter((loop) => loop.name === pace.band).length).toBe(3);

          if (out) {
            const dir = path.join(out, "shimmer-pacing");
            mkdirSync(dir, { recursive: true });
            for (const at of STILLS) {
              await page.evaluate((fraction) => {
                for (const animation of document.getAnimations()) {
                  animation.currentTime = Number(animation.effect?.getTiming().duration) * fraction;
                }
              }, at);
              await page.evaluate(
                () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))),
              );
              await page.screenshot({
                path: path.join(dir, `${variant}-${String(Math.round(at * 100)).padStart(2, "0")}.png`),
              });
            }
          }
        } finally {
          await page.close();
        }
      });
  });
});
