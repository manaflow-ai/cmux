// Suggestion lists float (cx-6k6cg): opening one, or filtering it, never moves the content around
// it. In Chromium on the gallery stage (the real components on the gallery host), each case records
// the boxes of the content under or around a list, opens the list (or narrows it), and checks the
// boxes again, to the pixel:
// - the classic New Tab page's suggestions: the actions under the field stay put;
// - the composer's slash menu: the transcript and the composer stay put;
// - the folder picker's filter: its search field stays put while the list shrinks.
// Keyboard navigation is unchanged: ArrowDown moves the selection inside the open list.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("suggestion-lists-float.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("suggestion-lists-float: skipping (run `bunx playwright install chromium`)");
    describe.skip("suggestion lists float", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stageURL = (entry: string, variant: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  const stage = async (entry: string, variant: string) => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    for (let attempt = 0; ; attempt += 1) {
      await page.goto(stageURL(entry, variant));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        return page;
      } catch (error) {
        // The first load can hit Vite's dependency optimizer, which reloads the page once.
        if (attempt > 1 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  };

  /** Every finite animation on the page done: a menu's entrance travels a few points (ui-popup-in). */
  const settled = (page: Page) =>
    page.evaluate(async () => {
      await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
      const finite = document
        .getAnimations()
        .filter((animation) => Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)));
      await Promise.all(finite.map((animation) => animation.finished.catch(() => undefined)));
    });

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer", "agent-pane.new-tab"], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** Each selector's box (rounded to the pixel), or null when it is not on the page. */
  const boxes = (page: Page, selectors: string[]) =>
    page.evaluate((selectors) => {
      const result: Record<string, number[] | null> = {};
      for (const selector of selectors) {
        const box = document.querySelector(selector)?.getBoundingClientRect();
        result[selector] = box ? [box.left, box.top, box.width, box.height].map(Math.round) : null;
      }
      return result;
    }, selectors);

  test("the classic New Tab page's suggestions float over the actions under the field", async () => {
    const page = await stage("agent-pane.new-tab", "template-classic");
    const under = [".acpmux-newtab-box", ".acpmux-newtab-actions"];
    // "All sessions" takes a click at rest: no list covers it.
    const reachable = () =>
      page.evaluate(() => {
        const button = document.querySelector(".acpmux-newtab-all")!;
        const box = button.getBoundingClientRect();
        return button.contains(document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2));
      });
    await page.click(".acpmux-newtab-field");
    expect(await page.locator(".acpmux-omni").count()).toBe(0);
    expect(await reachable()).toBe(true);
    const before = await boxes(page, under);
    await page.keyboard.type("a");
    await page.waitForSelector(".acpmux-omni [role=option]");
    expect(await boxes(page, under)).toEqual(before);
    const selected = () => page.getAttribute(".acpmux-omni [aria-selected=true]", "id");
    const first = await selected();
    await page.keyboard.press("ArrowDown");
    expect(await selected()).not.toBe(first);
    // Leaving the field closes the list; the page under it is reachable again.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.waitForSelector(".acpmux-omni", { state: "detached" });
    expect(await reachable()).toBe(true);
    await page.close();
  });

  test("the composer's slash menu floats over the transcript", async () => {
    const page = await stage("agent-pane.composer", "idle");
    const under = [".acpmux-scroll", ".acpmux-composer-box"];
    const before = await boxes(page, under);
    await page.click("[contenteditable='true']");
    await page.keyboard.type("/");
    await page.waitForSelector(".acpmux-slash-menu [role=option]");
    expect(await boxes(page, under)).toEqual(before);
    await page.close();
  });

  test("filtering the folder picker keeps its search field in place", async () => {
    const page = await stage("agent-pane.composer", "agent-home-folders");
    const field = ".acpmux-location-menu input";
    await page.waitForSelector(field);
    const rows = () => page.locator(".acpmux-location-menu [role=option]").count();
    await settled(page);
    const before = await boxes(page, [field, ".acpmux-composer-box"]);
    const all = await rows();
    await page.focus(field);
    await page.keyboard.type("zz");
    await page.waitForFunction(
      (all) => document.querySelectorAll(".acpmux-location-menu [role=option]").length < all,
      all,
    );
    expect(await rows()).toBeLessThan(all);
    await settled(page);
    expect(await boxes(page, [field, ".acpmux-composer-box"])).toEqual(before);
    await page.close();
  });
});
