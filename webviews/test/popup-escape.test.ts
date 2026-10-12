// Small surfaces with no room go past the window's edge (cx-6k6cg). In Chromium on the gallery
// stage, the agent pane runs on the gallery's stand-in for the app's pane bridge; this test wraps
// that bridge so `popup.show/update/hide` are recorded and answered as the app's host does
// (WebPopupHost), and sends the host's events back as the app does (the `cmux-popup` event).
// In a 600x400 window the composer's commands list has no room above the prompt:
// - its rows go to the host, every one of them, and the page's list goes invisible without moving
//   the transcript or the composer;
// - the keyboard stays in the prompt: ArrowDown moves the host's highlight;
// - a pick in the host runs the page's row (the command lands in the prompt) and ends the panel.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popup-escape.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("popup-escape: skipping (run `bunx playwright install chromium`)");
    describe.skip("popup escape", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stage = async (entry: string, variant: string, viewport: { width: number; height: number }) => {
    const page = await browser!.newPage({ viewport });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 0; ; attempt += 1) {
      await page.goto(`http://127.0.0.1:${port}/gallery/frame.html?entry=${entry}&variant=${variant}`);
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

  /** Records the pane's popup calls and answers them as the app's host does. */
  const recordPopups = (page: Page) =>
    page.evaluate(() => {
      const calls: { method: string; params: Record<string, unknown> }[] = [];
      (window as unknown as { popupCalls: typeof calls }).popupCalls = calls;
      const handler = (
        window as unknown as {
          webkit: { messageHandlers: { agentSession: { postMessage(message: unknown): Promise<unknown> } } };
        }
      ).webkit.messageHandlers.agentSession;
      const post = handler.postMessage.bind(handler);
      handler.postMessage = (message) => {
        const { method, params } = message as { method?: string; params?: Record<string, unknown> };
        if (!method?.startsWith("popup.")) return post(message);
        calls.push({ method, params: params ?? {} });
        return Promise.resolve({ ok: true, value: method === "popup.show" ? { shown: true } : {} });
      };
    });

  const popupCalls = (page: Page) =>
    page.evaluate(
      () => (window as unknown as { popupCalls: { method: string; params: Record<string, unknown> }[] }).popupCalls,
    );

  const boxes = (page: Page, selectors: string[]) =>
    page.evaluate((selectors) => {
      const result: Record<string, number[] | null> = {};
      for (const selector of selectors) {
        const box = document.querySelector(selector)?.getBoundingClientRect();
        result[selector] = box ? [box.left, box.top, box.width, box.height].map(Math.round) : null;
      }
      return result;
    }, selectors);

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await (await stage("agent-pane.composer", "idle", { width: 900, height: 700 })).close();
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a 600x400 window sends the commands list past its edge, keyboard and pick intact", async () => {
    const page = await stage("agent-pane.composer", "slash-menu-full", { width: 600, height: 400 });
    // The variant's play opened the list before the recorder; clear the prompt and open it again.
    await page.click("[contenteditable='true']");
    await page.keyboard.press("Backspace");
    await page.waitForSelector("#acpmux-slash-menu", { state: "detached" });
    await recordPopups(page);
    const under = [".acpmux-scroll", ".acpmux-composer-box"];
    const before = await boxes(page, under);
    await page.keyboard.type("/");
    await page.waitForSelector("#acpmux-slash-menu[data-escaped]", { state: "attached", timeout: 10_000 });
    const rows = await page.locator("#acpmux-slash-menu [role=option]").count();
    const show = (await popupCalls(page)).find((call) => call.method === "popup.show");
    expect(show?.params).toMatchObject({ kind: "list", side: "top", highlighted: "0" });
    expect(show?.params.items as unknown[] | undefined).toHaveLength(rows);
    expect(rows).toBeGreaterThan(1);
    // The page's list is invisible and moved nothing.
    expect(await page.$eval("#acpmux-slash-menu", (list) => getComputedStyle(list).opacity)).toBe("0");
    expect(await boxes(page, under)).toEqual(before);
    // The prompt keeps the keyboard; the host's highlight follows.
    await page.keyboard.press("ArrowDown");
    await page.waitForFunction(() =>
      (window as unknown as { popupCalls: { method: string; params: { highlighted?: string } }[] }).popupCalls.some(
        (call) => call.method === "popup.update" && call.params.highlighted === "1",
      ),
    );
    expect(await page.evaluate(() => document.activeElement?.getAttribute("contenteditable"))).toBe("true");
    // A pick in the host runs the page's row: its command lands in the prompt, the panel ends.
    const name = (await page.locator("#acpmux-slash-menu [role=option] .acpmux-slash-name").nth(2).innerText()).trim();
    await page.evaluate(() =>
      window.dispatchEvent(new CustomEvent("cmux-popup", { detail: { type: "pick", id: "2" } })),
    );
    await page.waitForSelector("#acpmux-slash-menu", { state: "detached" });
    expect(await page.locator("[contenteditable='true']").innerText()).toContain(name);
    expect((await popupCalls(page)).some((call) => call.method === "popup.hide")).toBe(true);
    await page.close();
  });
});
