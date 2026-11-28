// P0 #8 (Leo, on a preview build): the reasoning control could not be clicked on its own. On the
// New Tab composer and a new chat's composer, before the session reported its options, the
// Reasoning chip was a picture (PendingChip: aria-hidden, pointer-events: none): a click fell
// through to the chips row, Tab skipped it, and the only way to the levels was the model chip's
// menu. Reasoning is its own control: its own hit target, its own accessible name, its own menu.
//
// At the boundary a person meets, in real Chromium: a pointer press at each chip's centre (so
// whatever is on top takes it) at 760, 400 and 300 px, on the New Tab page, a new chat and a live
// chat; and Tab from the model chip lands on the reasoning chip, each with its own name.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("reasoning-own-control.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reasoning-own-control: skipping (run `bunx playwright install chromium`)");
    describe.skip("reasoning own control", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (entry: string, variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=${entry}&variant=${variant}&frame=component&width=${width}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/gallery/frame.html");
    browser = await chromium.launch({ headless: true });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    const warm = await browser.newPage({ viewport: { width: 800, height: 600 } });
    await warm.goto(url("agent-pane.composer", "new-chat-reasoning", 760));
    for (;;) {
      try {
        await warm.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 0 });
        break;
      } catch (error) {
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await warm.close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (entry: string, variant: string, width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: width + 40, height: 640 } });
    await page.goto(url(entry, variant, width));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".acpmux-chips .acpmux-model .acpmux-picker-button").waitFor();
    await page.locator(".acpmux-chips .acpmux-effort").waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Presses the pointer at the centre of `selector`'s box: whatever is on top there takes it. */
  const pressCentre = async (page: Page, selector: string) => {
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error(`${selector} has no box`);
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
  };

  /** Which menus are open: the reasoning menu and the model picker. */
  const menus = (page: Page) =>
    page.evaluate(() => ({
      reasoning: document.querySelector(".acpmux-effort-menu") !== null,
      model: document.querySelector(".acpmux-mp") !== null,
    }));

  const cases: [string, string, string][] = [
    ["New Tab", "agent-pane.new-tab", "reasoning-chip"],
    ["new chat", "agent-pane.composer", "new-chat-reasoning"],
    ["live chat", "agent-pane.composer-row", "claude-auto"],
  ];
  for (const [where, entry, variant] of cases)
    for (const width of [760, 400, 300]) {
      test(`${where} at ${width} px: the reasoning chip opens the reasoning menu, the model chip the model menu`, async () => {
        const page = await open(entry, variant, width);
        await pressCentre(page, ".acpmux-chips .acpmux-effort");
        await page.locator(".acpmux-effort-menu").waitFor();
        expect(await menus(page)).toEqual({ reasoning: true, model: false });
        await page.keyboard.press("Escape");
        await page.locator(".acpmux-effort-menu").waitFor({ state: "detached" });
        expect(await menus(page)).toEqual({ reasoning: false, model: false });
        await pressCentre(page, ".acpmux-chips .acpmux-model .acpmux-picker-button");
        await page.locator(".acpmux-mp").waitFor();
        expect(await menus(page)).toEqual({ reasoning: false, model: true });
        await page.close();
      });

      test(`${where} at ${width} px: Tab reaches the model and reasoning chips separately, each by its own name`, async () => {
        const page = await open(entry, variant, width);
        await page.locator(".acpmux-chips .acpmux-model .acpmux-picker-button").focus();
        const named = () =>
          page.evaluate(() => {
            const focused = document.activeElement as HTMLElement | null;
            return {
              name: focused?.getAttribute("aria-label") ?? "",
              chip: focused?.closest(".acpmux-model") ? "model" : focused?.closest(".acpmux-effort") ? "effort" : "",
            };
          });
        expect(await named()).toEqual({ name: "Model", chip: "model" });
        await page.keyboard.press("Tab");
        expect(await named()).toEqual({ name: "Effort", chip: "effort" });
        // Its own name in the accessibility tree, beside the model chip's.
        expect(await page.getByRole("button", { name: "Effort", exact: true }).count()).toBe(1);
        expect(await page.getByRole("button", { name: "Model", exact: true }).count()).toBe(1);
        await page.close();
      });
    }
});
