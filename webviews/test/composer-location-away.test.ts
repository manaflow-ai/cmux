// Leo 2026-10-29: "project and cloudness at the top. make them open away from teh chat, which is
// obviously up if it's up, down if it's down." The gallery's `agent-pane.composer-context-away`
// plays open the folder and machine menus of a new chat's composer (at the pane's foot) and of New
// Tab's (high on the page) and fail when a menu opens toward the conversation or leaves the
// window; this runs them in Chromium and checks they passed.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { playFailures } from "./support/galleryPlay";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-location-away.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-location-away: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer location away", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const entry = "agent-pane.composer-context-away";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "chat-folder" } });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const cases: [variant: string, height: number, what: string][] = [
    ["chat-folder", 560, "a new chat's folder menu opens down, over its composer"],
    ["chat-computer", 560, "a new chat's machine menu opens down, over its composer"],
    ["newtab-folder", 720, "New Tab's folder menu opens up, away from the chats under it"],
    ["newtab-computer", 720, "New Tab's machine menu opens up, away from the chats under it"],
  ];
  for (const [variant, height, what] of cases)
    test(what, async () => {
      const page = await browser!.newPage({ viewport: { width: 760, height } });
      try {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
        await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay), undefined, {
          timeout: 90_000,
        });
        const report = await page.evaluate(() =>
          JSON.stringify((window as unknown as { cmuxGalleryPlayReport?: unknown }).cmuxGalleryPlayReport),
        );
        // The play throws when the menu opens toward the chat or leaves the window.
        expect(playFailures(report)).toEqual([]);
      } finally {
        await page.close();
      }
    });
});
