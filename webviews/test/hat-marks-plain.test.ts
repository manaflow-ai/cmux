// The composer hat's header draws every agent mark plain: the harness's logo, never the session's
// sparkle badge over it (AgentIdentity.tsx `plain`). Leo, 2026-11-23, on a colored badge on every
// Claude mark in the hat: "weird and bad and unncessary"; the `kinds` header (KindMark) and the deck
// (HatHeadDeck) still drew it, top left of the hat (Leo, 2026-11-27: "there was a really dumb looking
// symbol in the top left of the composer hat when i loaded into this chat"). Measured in the gallery's
// real pane under the default Sender Icon look, whose badge is the diamond.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hat-marks-plain.test.ts", async () => {
  setDefaultTimeout(300_000);
  const CASES = [
    { entry: "agent-pane.feel-tray", variant: "one" },
    { entry: "agent-pane.composer-goal", variant: "with-hat" },
  ] as const;
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      root: path.resolve(import.meta.dir, ".."),
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, CASES[0].entry, { browser, params: { variant: CASES[0].variant } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  for (const { entry, variant } of CASES)
    test(`${entry}/${variant}: the hat's header marks carry no session badge`, async () => {
      const port = (server.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width: 900, height: 720 }, reducedMotion: "reduce" });
      try {
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: "normal" })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.waitForSelector(".acpmux-running-tray__head");
        const found = await page.evaluate(() => {
          const head = document.querySelector(".acpmux-running-tray__head")!;
          return {
            marks: head.querySelectorAll(".acpmux-running-tray__stack-mark, .acpmux-hat-deck__face").length,
            badged: head.querySelectorAll(".cv-sender-icon[data-badged], .cv-sender-icon").length,
          };
        });
        expect(found.marks).toBeGreaterThan(0);
        expect(found.badged).toBe(0);
      } finally {
        await page.close();
      }
    });
});
