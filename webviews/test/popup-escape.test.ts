// Small surfaces with no room go past the window's edge (cx-6k6cg). In Chromium on the gallery
// stage, the agent pane runs on the gallery's stand-in for the app's pane bridge; this test wraps
// that bridge so `popup.show/update/hide` are recorded and answered as the app's host does
// (WebPopupHost), and sends the host's events back as the app does (the `cmux-popup` event).
// In a 600x360 window the composer's commands list has no room above the prompt (at 400px its
// capped 296px list just fits over the prompt once the gallery's cascade matched the app's,
// a5393bc0de6f, so it rightly stays in the page there):
// - its rows go to the host, every one of them, and the page's list goes invisible without moving
//   the transcript or the composer;
// - the keyboard stays in the prompt: ArrowDown moves the host's highlight;
// - a pick in the host runs the page's row (the command lands in the prompt) and ends the panel.
// In a pane 180px tall, the prompt's context menu has room on neither side of the pointer: its rows
// go to the host the same way, the arrows move the host's highlight, and a pick runs the item.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
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
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant })}`);
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
    await warmGalleryFrame(vite, "agent-pane.composer", { browser, params: { variant: "idle" } });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("a 600x360 window sends the commands list past its edge, keyboard and pick intact", async () => {
    const page = await stage("agent-pane.composer", "slash-menu-full", { width: 600, height: 360 });
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

  test("a short pane sends the prompt's context menu past its edge, keyboard and pick intact", async () => {
    const page = await stage("agent-pane.composer", "context-menu", { width: 600, height: 180 });
    // The variant's play opened the menu before the recorder; close it and open it again.
    await page.dispatchEvent(".ui-context-menu-backdrop", "pointerdown");
    await page.waitForSelector(".ui-context-menu", { state: "detached" });
    await recordPopups(page);
    const under = [".acpmux-composer-box"];
    const before = await boxes(page, under);
    // Right-click over the selected prompt text, as the variant's play does.
    await page.evaluate(() => {
      const field = document.querySelector(".acpmux-md")!;
      getSelection()!.selectAllChildren(field);
      const box = field.getBoundingClientRect();
      field.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          clientX: box.left + 40,
          clientY: box.top + 12,
        }),
      );
    });
    await page.waitForSelector(".ui-context-menu[data-escaped]", { state: "attached", timeout: 10_000 });
    // Its rows: the actions and, last, the "Scroll to bottom when I send" checkbox (#25690).
    const ROWS = ".ui-context-menu :is([role=menuitem], [role=menuitemcheckbox])";
    const rows = await page.locator(ROWS).count();
    const show = (await popupCalls(page)).find((call) => call.method === "popup.show");
    expect(show?.params).toMatchObject({ kind: "menu", side: "bottom" });
    // Every row, its separator and its disabled state as the page has them.
    const items = show?.params.items as { label?: string; separator?: boolean; disabled?: boolean }[];
    // ArrowDown skips separators and disabled rows (Redo with no history, after Undo).
    const from = Number(show?.params.highlighted);
    const next = String(items.findIndex((item, index) => index > from && !item.separator && !item.disabled));
    expect(next).not.toBe("-1");
    expect(items.filter((item) => !item.separator).map((item) => item.disabled)).toEqual(
      await page.$$eval(ROWS, (all) => all.map((row) => row.hasAttribute("disabled"))),
    );
    expect(items.some((item) => item.separator)).toBe(true);
    expect(rows).toBeGreaterThan(3);
    expect(await page.$eval(".ui-context-menu", (menu) => getComputedStyle(menu).opacity)).toBe("0");
    expect(await boxes(page, under)).toEqual(before);
    await page.keyboard.press("ArrowDown");
    await page.waitForFunction(
      (next) =>
        (window as unknown as { popupCalls: { method: string; params: { highlighted?: string } }[] }).popupCalls.some(
          (call) => call.method === "popup.update" && call.params.highlighted === next,
        ),
      next,
    );
    // A hover in the host, then the arrows: the host follows the page's highlight, not the hovered row.
    const lastId = String(items.length - 1);
    await page.evaluate(
      (id) => window.dispatchEvent(new CustomEvent("cmux-popup", { detail: { type: "highlight", id } })),
      lastId,
    );
    await page.keyboard.press("ArrowUp");
    await page.waitForFunction(
      (above) =>
        (window as unknown as { popupCalls: { method: string; params: { highlighted?: string } }[] }).popupCalls.at(-1)
          ?.params.highlighted === above,
      // The row above the last, past its separator.
      String(
        items
          .map((item, index) => (index < items.length - 1 && !item.separator && !item.disabled ? index : -1))
          .reduce((last, index) => Math.max(last, index), -1),
      ),
    );
    // Insert Mention picked in the host: its @ lands in the prompt, the panel ends.
    const mention = String(items.findIndex((item) => item.label === "Insert Mention"));
    expect(mention).not.toBe("-1");
    await page.evaluate(
      (id) => window.dispatchEvent(new CustomEvent("cmux-popup", { detail: { type: "pick", id } })),
      mention,
    );
    await page.waitForSelector(".ui-context-menu", { state: "detached" });
    expect(await page.locator("[contenteditable='true']").innerText()).toContain("@");
    expect((await popupCalls(page)).some((call) => call.method === "popup.hide")).toBe(true);
    await page.close();
  });

  /** Types `query` into `field` with the recorder on; the list escapes, keyboard and pick intact. */
  const checkSuggestions = async (
    page: Page,
    field: string,
    list: string,
    query: string,
    side: "top" | "bottom" = "bottom",
  ) => {
    await page.click(field);
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    await page.waitForSelector(`${list} [role=option]`, { state: "detached" });
    await recordPopups(page);
    await page.keyboard.type(query);
    await page.waitForSelector(`${list}[data-escaped], [data-escaped] > ${list}`, {
      state: "attached",
      timeout: 10_000,
    });
    // The panel escapes on the first key and follows the rows as the rest of the query lands
    // (popup.update): every row the page has now is in the host's latest model.
    await page.waitForFunction((list) => {
      const calls = (window as unknown as { popupCalls: { params: { items?: unknown[] } }[] }).popupCalls;
      return calls.at(-1)?.params.items?.length === document.querySelectorAll(`${list} [role=option]`).length;
    }, list);
    const rows = await page.locator(`${list} [role=option]`).count();
    const calls = await popupCalls(page);
    expect(calls.find((call) => call.method === "popup.show")?.params).toMatchObject({ kind: "list", side });
    const show = calls.filter((call) => call.method === "popup.show" || call.method === "popup.update").at(-1);
    expect(show?.params.items as unknown[] | undefined).toHaveLength(rows);
    expect(rows).toBeGreaterThan(1);
    // The field keeps the keyboard; the host's highlight follows the arrows to the page's row.
    const before = await popupCalls(page).then((calls) => calls.length);
    await page.keyboard.press("ArrowDown");
    await page.waitForFunction(
      ([list, before]) => {
        const calls = (window as unknown as { popupCalls: { method: string; params: { highlighted?: string } }[] })
          .popupCalls;
        const rows = [...document.querySelectorAll(`${list} [role=option]`)];
        const selected = String(rows.findIndex((row) => row.getAttribute("aria-selected") === "true"));
        return calls.length > before && calls.at(-1)?.params.highlighted === selected;
      },
      [list, before] as const,
    );
    expect(["INPUT", "TEXTAREA"]).toContain(await page.evaluate(() => document.activeElement?.tagName ?? ""));
    // The host's labels are the rows' words, spaced, without the Return hint the selected row shows.
    const labels = ((show?.params.items ?? []) as { label: string }[]).map((item) => item.label);
    for (const label of labels) expect(label).not.toContain("↵");
    // A dismiss from the host (another app, a resize) hides the rows and keeps the typed text.
    const typed = await page.inputValue(field);
    await page.evaluate(() => window.dispatchEvent(new CustomEvent("cmux-popup", { detail: { type: "dismiss" } })));
    await page.waitForSelector(`${list} [role=option]`, { state: "detached" });
    expect(await page.inputValue(field)).toBe(typed);
    expect((await popupCalls(page)).some((call) => call.method === "popup.hide")).toBe(true);
    // Typing again brings them back.
    await page.keyboard.type("e");
    await page.waitForSelector(`${list} [role=option]`, { state: "attached" });
    return labels;
  };

  test("a short window sends the New Tab suggestions past its edge", async () => {
    const page = await stage("agent-pane.new-tab", "typed-tab-match", { width: 600, height: 260 });
    // The default (Cards) template's field heads the page, so its rows open under it.
    const labels = await checkSuggestions(page, ".nt-field", ".nt-rows", "release");
    expect(labels).toContain("Release notes cmux.dev");
    await page.close();
  });

  test("a short window sends the stage layout's New Tab suggestions past its edge, above the composer", async () => {
    const page = await stage("agent-pane.new-tab", "typed-tab-match-stage", { width: 600, height: 260 });
    // Default's stage layout keeps the composer at the foot of the page, so its rows open above it.
    const labels = await checkSuggestions(page, ".nt-field", ".nt-rows", "release", "top");
    expect(labels).toContain("Release notes cmux.dev");
    await page.close();
  });

  test("a short window sends the classic New Tab suggestions past its edge", async () => {
    const page = await stage("agent-pane.new-tab", "template-classic", { width: 600, height: 300 });
    await checkSuggestions(page, ".acpmux-newtab-field", ".acpmux-omni", "a");
    await page.close();
  });
});
