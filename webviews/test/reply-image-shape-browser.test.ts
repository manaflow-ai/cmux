// l10n-allow-file: browser fixture labels and diagnostics, not shipped UI.
// cmux-web-test-timeout: 240
// A chat image's thumbnail is the whole image in its own shape (Leo, 2026-11-05: "I don't think we
// have good enough looking previews for these"): a reply's image path (chips.css .cv-thumb--open) is
// no fixed 16:10 card with the image a thin strip in its middle, and a sent image (UserBubble.tsx
// sentImageSize) is no magnified crop of a wide screenshot's middle. Neither draws an image larger
// than it is. Gallery entries agent-pane.reply-thumbs and agent-pane.sent-images, in Chromium.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/reply-image-shape-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("reply-image-shape-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const captures = process.env.CMUX_REPLY_IMAGE_CAPTURE_DIR || process.env.FAST_CHECKS_OUT;
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
    await warmGalleryFrame(vite, "agent-pane.reply-thumbs", { browser, params: { variant: "wide-strip" } });
    if (captures) await mkdir(captures, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Measure = { frame: DOMRect; image: DOMRect; natural: { width: number; height: number } };
  const cases = [
    { entry: "agent-pane.reply-thumbs", variant: "wide-strip", image: ".cv-thumb__img", frame: ".cv-thumb" },
    { entry: "agent-pane.reply-thumbs", variant: "tall-phone", image: ".cv-thumb__img", frame: ".cv-thumb" },
    // A row of a wide, a tall and a square image: each keeps its shape inside its share.
    { entry: "agent-pane.reply-thumbs", variant: "shapes", image: ".cv-thumb__img", frame: ".cv-thumb" },
    { entry: "agent-pane.sent-images", variant: "wide-strip", image: "img.cv-user__image", frame: "button" },
    { entry: "agent-pane.sent-images", variant: "pasted", image: "img.cv-user__image", frame: "button" },
  ];
  for (const { entry, variant, image, frame } of cases)
    for (const colorScheme of ["dark", "light"] as const)
      test(`${entry} ${variant}: the whole image in its own shape (${colorScheme})`, async () => {
        const page = await browser!.newPage({
          viewport: { width: 760, height: 720 },
          colorScheme,
          deviceScaleFactor: 2,
        });
        try {
          const base = `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}`;
          await page.goto(base + galleryFrame(entry, { variant, colorScheme, width: 760, height: 720 }));
          await page.waitForFunction(() =>
            ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
          );
          expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
          await page.waitForFunction((selector) => {
            const all = [...document.querySelectorAll<HTMLImageElement>(selector)];
            return all.length > 0 && all.every((img) => img.complete && img.naturalWidth > 0);
          }, image);
          if (captures)
            await page.screenshot({
              path: path.join(captures, `${entry.split(".")[1]}-${variant}-${colorScheme}.png`),
            });
          const measured: Measure[] = await page.evaluate(
            ({ image, frame }) =>
              [...document.querySelectorAll<HTMLImageElement>(image)].map((img) => ({
                frame: (img.closest(frame) ?? img).getBoundingClientRect().toJSON(),
                image: img.getBoundingClientRect().toJSON(),
                natural: { width: img.naturalWidth, height: img.naturalHeight },
              })),
            { image, frame },
          );
          expect(measured.length).toBeGreaterThan(0);
          for (const { frame: box, image: drawn, natural } of measured) {
            const label = `${natural.width}×${natural.height} drawn ${drawn.width.toFixed(1)}×${drawn.height.toFixed(1)} in ${box.width.toFixed(1)}×${box.height.toFixed(1)}`;
            // The box the reader sees is the image's own shape: no crop, no empty card around it.
            expect(Math.abs(box.width / box.height - natural.width / natural.height), label).toBeLessThan(
              (natural.width / natural.height) * 0.04 + 0.02,
            );
            expect(Math.abs(box.width - drawn.width), label).toBeLessThan(2);
            expect(Math.abs(box.height - drawn.height), label).toBeLessThan(2);
            // Never larger than the image: no magnified, blurry crop.
            expect(drawn.width, label).toBeLessThanOrEqual(natural.width + 0.5);
          }
        } finally {
          await page.close();
        }
      });
});
