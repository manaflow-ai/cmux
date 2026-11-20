// l10n-allow-file: gallery assertions, not shipped UI.
// A checked task fills only its own box: an unchecked subtask under it stays empty, in a tight list
// (the box straight in the item) and a loose one (the box in the item's paragraph).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("github-page-tasks.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "../..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "pages.github", { browser, timeoutMs: 120_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a checked task's subtask keeps an empty box", async () => {
    const page = await browser.newPage({ viewport: { width: 1200, height: 900 } });
    try {
      await page.goto(`${base}${galleryFrame("pages.github", { variant: "open", reducedMotion: 1 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.locator(".gh-md").first().waitFor();
      const fills = await page.evaluate(() => {
        const host = document.querySelector(".gh-md")!;
        const box = '<span class="gh-md-task"></span>';
        host.insertAdjacentHTML(
          "beforeend",
          `<ul id="tight"><li data-task="done">${box}parent<ul><li data-task="open">${box}child</li></ul></li></ul>` +
            `<ul id="loose"><li data-task="done"><p>${box}parent</p><ul><li data-task="open"><p>${box}child</p></li></ul></li></ul>`,
        );
        const fill = (selector: string) => getComputedStyle(document.querySelector(selector)!).backgroundColor;
        return {
          tightParent: fill("#tight > li > .gh-md-task"),
          tightChild: fill("#tight li li .gh-md-task"),
          looseParent: fill("#loose > li > p > .gh-md-task"),
          looseChild: fill("#loose li li .gh-md-task"),
        };
      });
      const empty = "rgba(0, 0, 0, 0)";
      expect(fills.tightParent).not.toBe(empty);
      expect(fills.looseParent).not.toBe(empty);
      expect(fills.tightChild).toBe(empty);
      expect(fills.looseChild).toBe(empty);
    } finally {
      await page.close();
    }
  });
});
