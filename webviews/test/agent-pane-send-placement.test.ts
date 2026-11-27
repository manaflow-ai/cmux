// l10n-allow-file: browser fixture diagnostics, not shipped UI.
// cmux-web-test-timeout: 600
// cmux-web-test-alone
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

type Placement = {
  before: { top: number; overflow: number };
  promptTop: number;
  scrollerTop: number;
  fromEnd: number;
  frames: { t: number; sent: number | null; prev: number | null }[];
};

await requireBrowserLane("agent-pane-send-placement.test.ts", async () => {
  if (!(await probeEngineOrSkip("agent-pane-send-placement.test.ts", "chromium", chromium))) return;
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.send-placement";
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "default-latest" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const variant of ["default-latest", "top-long", "top-short"])
    test(`${variant}: the send lands in the selected place`, async () => {
      const page = await browser.newPage({
        viewport: { width: 1000, height: 800 },
        reducedMotion: "no-preference",
      });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: 900 })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady !== undefined, undefined, {
          timeout: 180_000,
        });
        const evidence = await page.evaluate(() => ({
          placement: document.documentElement.dataset.sendPlacement,
          report: JSON.stringify((window as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
        }));
        if (process.env.FAST_CHECKS_OUT) {
          await mkdir(process.env.FAST_CHECKS_OUT, { recursive: true });
          const file = path.join(process.env.FAST_CHECKS_OUT, `send-placement-${variant}`);
          await page.screenshot({ path: `${file}.png` });
          await Bun.write(`${file}.json`, JSON.stringify(evidence, null, 2));
        }
        expect(playFailures(evidence.report)).toEqual([]);
        expect(evidence.placement).toBeDefined();
        const result = JSON.parse(evidence.placement!) as Placement;
        const inset = result.promptTop - result.scrollerTop;
        console.log(`${variant}: prompt inset ${inset}px; latest gap ${result.fromEnd}px`);
        if (variant === "default-latest") {
          expect(result.before.overflow).toBeGreaterThan(0);
          expect(result.fromEnd).toBeLessThanOrEqual(2);
          expect(inset).toBeGreaterThan(40);
        } else {
          expect(Math.abs(inset - 16)).toBeLessThanOrEqual(2);
          if (variant === "top-short") expect(result.before.overflow).toBeLessThanOrEqual(2);
          else {
            expect(result.before.overflow).toBeGreaterThan(0);
            const sent = result.frames.flatMap((frame) => (frame.sent === null ? [] : [frame.sent]));
            expect(sent.length).toBeGreaterThan(3);
            const start = sent[0]!;
            const end = sent.at(-1)!;
            expect(start - end).toBeGreaterThan(24);
            // A cut to the top fails this even if its final geometry is right. Require distinct
            // positions strictly between the endpoints, so a delayed one-frame jump also fails.
            const between = sent.filter((top) => top < start - 2 && top > end + 2);
            expect(new Set(between.map((top) => Math.round(top))).size).toBeGreaterThanOrEqual(2);
            for (let index = 1; index < sent.length; index += 1)
              expect(sent[index]!).toBeLessThanOrEqual(sent[index - 1]! + 2);
          }
        }
      } finally {
        await page.close();
      }
    });
});
