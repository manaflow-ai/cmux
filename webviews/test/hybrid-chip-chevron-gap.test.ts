// The hybrid cloud button's holders menu draws its name and its chevron after it ("acpmux⌄"), now
// through the shared DisclosureFace (no text glyph).
// Leo, 2026-11-27: "these chevrons are too close dont we have any guidelines for these yet?"
// The chevron's ink starts 3-8px (design/chevrons.md) after the name's last ink, wide and narrow.
// Source: hybrid/CloudTriToggle.tsx, .acpmux-hybrid-tri__name .ui-disclosure-chevron.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hybrid-chip-chevron-gap.test.ts", async () => {
  setDefaultTimeout(240_000);
  const MIN_GAP = 3;
  const MAX_GAP = 8;
  const ENTRY = "agent-pane.hybrid-cloud-toggle";
  const VARIANT = "chat-above-three-state-full-holders";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("hybrid chip chevron gap", () => test("browser", () => {}));
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
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  describe("hybrid chip chevron gap", () => {
    for (const width of [720, 400]) {
      test(`the holders button's chevron starts ${MIN_GAP}-${MAX_GAP}px after its name at ${width}px`, async () => {
        const page = await browser.newPage({ viewport: { width: width + 40, height: 600 }, deviceScaleFactor: 2 });
        try {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width, reducedMotion: "true" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 120_000,
          });
          await page.evaluate(() => document.fonts.ready);
          const gap = await page.evaluate(() => {
            const chevron = document.querySelector(".acpmux-hybrid-tri__name .ui-disclosure-chevron");
            const button = chevron?.closest("button");
            if (!chevron || !button) return null;
            const walker = document.createTreeWalker(button, NodeFilter.SHOW_TEXT);
            let end: number | null = null;
            for (let node = walker.nextNode(); node; node = walker.nextNode()) {
              if (chevron.contains(node) || !node.textContent?.trim()) continue;
              const range = document.createRange();
              range.selectNodeContents(node);
              for (const rect of range.getClientRects()) end = Math.max(end ?? 0, rect.right);
            }
            const paths = [...chevron.querySelectorAll("path, polyline, line")].map(
              (p) => p.getBoundingClientRect().left,
            );
            const inkLeft = paths.length ? Math.min(...paths) : chevron.getBoundingClientRect().left;
            return end === null ? null : inkLeft - end;
          });
          expect(gap).not.toBeNull();
          expect(gap!).toBeGreaterThanOrEqual(MIN_GAP - 0.5);
          expect(gap!).toBeLessThanOrEqual(MAX_GAP + 0.5);
        } finally {
          await page.close();
        }
      });
    }
  });
});
