// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 300
// A sent message's attachments draw where the composer placed them, in their final box from the
// first frame, whole (Leo, 2026-11-22: "i meant there were various resizing things going on, and you
// guys didn't predict the placements in time. there should be no problem doing so for inline
// attachments after send"). Each variant's play (src/gallery/fixtures/sentMedia.ts) holds the reads,
// snapshots every box, releases them, and fails on any move, layout shift, crop or band. The play
// writes its numbers before it judges, so this test prints them for a failing build (the before of
// a change) too, and with FAST_CHECKS_OUT (or CMUX_SENT_MEDIA_CAPTURE_DIR) keeps a still of each
// message, cropped to its bubble at one size.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/sent-media-holds-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("sent-media-holds-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  const IMAGES = "agent-pane.sent-images";
  const VIDEO = "agent-pane.sent-video";
  const CASES: [string, string][] = [
    [IMAGES, "placed-wide"],
    [IMAGES, "placed-mid-wide"],
    [IMAGES, "placed-tall"],
    [IMAGES, "placed-mid-portrait"],
    [IMAGES, "placed-several"],
    [IMAGES, "placed-several-one-line"],
    [IMAGES, "placed-text-before-only"],
    [IMAGES, "placed-half"],
    [IMAGES, "placed-third"],
    [IMAGES, "placed-quarter"],
    [VIDEO, "video-placed"],
    [VIDEO, "video-and-screenshot-placed-mid-sentence"],
    [VIDEO, "sent-video-wide"],
    [VIDEO, "sent-video-wide-alone"],
    [VIDEO, "sent-video-wide-after-text"],
    [VIDEO, "sent-video-16-9"],
    [VIDEO, "sent-video-portrait"],
    [VIDEO, "sent-video-square"],
    [VIDEO, "sent-video-without-frames-kept"],
    [VIDEO, "sent-video-half"],
    [VIDEO, "sent-video-third"],
    [VIDEO, "sent-video-quarter"],
  ];
  // One still size for every message, so a before and an after compare side by side.
  const STILL = { width: 620, height: 300 };
  const webviews = path.resolve(import.meta.dir, "..");
  const captures = process.env.CMUX_SENT_MEDIA_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
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
    for (const entry of [IMAGES, VIDEO])
      await warmGalleryFrame(vite, entry, { browser, params: { variant: CASES.find(([one]) => one === entry)![1] } });
    if (captures) await mkdir(captures, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [entry, variant] of CASES)
    test(`${entry} ${variant}: every attachment holds its box from the first frame, whole`, async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 700 }, deviceScaleFactor: 2 });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 900, reducedMotion: "true" })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
          timeout: 120_000,
        });
        const state = await page.evaluate(() => {
          const report = (window as { cmuxGalleryPlayReport?: { error?: string; steps?: { problems?: string[] }[] } })
            .cmuxGalleryPlayReport;
          const row = [...document.querySelectorAll(".cv-user")].at(-1)?.getBoundingClientRect();
          return {
            play: document.documentElement.dataset.galleryPlay,
            numbers: document.documentElement.dataset.sentMediaShift,
            error: report?.error ?? report?.steps?.flatMap((step) => step.problems ?? []).join("; "),
            row: row && { right: row.right, top: row.top },
          };
        });
        console.log(`sent-media ${entry}/${variant} ${state.play} ${state.numbers ?? "{}"} ${state.error ?? ""}`);
        if (captures && state.row) {
          const x = Math.max(0, Math.min(900 - STILL.width, state.row.right + 12 - STILL.width));
          await page.screenshot({
            path: path.join(captures, `${entry}--${variant}.png`),
            clip: { x, y: Math.max(0, state.row.top - 12), ...STILL },
          });
        }
        expect({ play: state.play, error: state.play === "fail" ? state.error : undefined }).toEqual({
          play: expect.not.stringMatching(/^fail$/),
          error: undefined,
        });
        expect(state.numbers).toBeDefined();
        const numbers = JSON.parse(state.numbers!) as { movedPx: number; cls: number };
        expect(numbers.movedPx).toBeLessThanOrEqual(0.5);
        expect(numbers.cls).toBeLessThanOrEqual(0.0001);
      } finally {
        await page.close();
      }
    });
});
