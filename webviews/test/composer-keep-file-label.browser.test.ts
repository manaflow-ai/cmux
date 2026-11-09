// An oversized paste's card carries Keep as .txt over its label row's end (attachmentIntake.tsx
// KeepFileButton). The label stops before it, in the strip's card and in the one placed in the
// prompt, so its size ("· N lines · NK characters") is never hidden under the action (review of
// #37516: "Keep as .txt sits over the size label and hides its trailing text").
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-keep-file-label.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-keep-file-label: skipping (run `bunx playwright install chromium`)");
    describe.skip("Keep as .txt label", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  /// Each host of the card: the strip's (its own gallery) and the prompt's inline one.
  const HOSTS = [
    { name: "strip", entry: "agent-pane.text-attachment-card", variant: "page" },
    { name: "inline", entry: "agent-pane.composer", variant: "text-pasted-inline" },
  ] as const;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const host of HOSTS) await warmGalleryFrame(vite, host.entry, { browser, params: { variant: host.variant } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const host of HOSTS)
    test(`${host.name}: the label ends before Keep as .txt`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(host.entry, { variant: host.variant })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        await page.waitForSelector(".acpmux-text-card .acpmux-attachment-keep-file", { timeout: 60_000 });
        const boxes = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>(".acpmux-text-card")]
            .filter((card) => card.querySelector(".acpmux-attachment-keep-file"))
            .map((card) => {
              const label = card.querySelector<HTMLElement>(".acpmux-text-card__label")!.getBoundingClientRect();
              const keep = card.querySelector<HTMLElement>(".acpmux-attachment-keep-file")!.getBoundingClientRect();
              return { labelRight: label.right, labelWidth: label.width, keepLeft: keep.left };
            }),
        );
        expect(boxes.length).toBeGreaterThan(0);
        for (const box of boxes) {
          expect(box.labelWidth).toBeGreaterThan(0);
          expect(box.labelRight).toBeLessThanOrEqual(box.keepLeft);
        }
      } finally {
        await page.close();
      }
    });
});
