// A press anywhere on the composer's card focuses the prompt, as in Codex and Claude Code, whose
// whole input card is the text area. Before, only the editable text took a press: the field's own
// padding, the gap around the button row and the card's edge left nothing focused, so a click a few
// pixels off the text dropped the keyboard. The card's buttons keep their own presses.
//
// The real agent pane (vite.config.acpmux-pane.mjs) with a stand-in host and the in-page mock
// transport. Chromium and WebKit; CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/composer-click-near-focuses.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-click-near-focuses.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-click-near-focuses: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer click near focuses", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function chat(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      const w = window as unknown as Record<string, unknown>;
      w.webkit = { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } };
      w.cmuxAcpmuxActions = { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: false }) };
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt .ProseMirror").waitFor();
    await page.waitForFunction(() => document.activeElement?.classList.contains("ProseMirror"));
    return page;
  }

  const inPrompt = (page: Page) =>
    page.evaluate(() => document.activeElement?.closest(".acpmux-composer-prompt") !== null);
  const prompt = (page: Page) => page.locator(".acpmux-composer-prompt .ProseMirror").innerText();
  const blur = (page: Page) => page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());

  for (const [name] of engines)
    describe(name, () => {
      test("a press on the card around the text focuses the prompt and keeps its caret", async () => {
        const page = await chat(browsers.get(name)!);
        await page.keyboard.type("compare the retry");
        const box = (await page.locator(".acpmux-composer-box").boundingBox())!;
        const field = (await page.locator(".acpmux-composer-prompt").boundingBox())!;
        const presses = [
          // The field's own left padding, beside the text.
          { x: field.x + 4, y: field.y + field.height / 2 },
          // The card's bottom edge, under the button row's middle.
          { x: box.x + box.width / 2, y: box.y + box.height - 4 },
        ];
        for (const [index, at] of presses.entries()) {
          await blur(page);
          expect(await inPrompt(page)).toBe(false);
          await page.mouse.click(at.x, at.y);
          expect({ press: index, focused: await inPrompt(page) }).toEqual({ press: index, focused: true });
        }
        await page.keyboard.type(" policies");
        expect((await prompt(page)).trim()).toBe("compare the retry policies");
        await page.close();
      });

      test("a press inside a menu the card opened is not a press on the card", async () => {
        const page = await chat(browsers.get(name)!);
        await page.locator(".acpmux-composer-plus").click();
        const menu = page.locator(".acpmux-menu").first();
        await menu.waitFor();
        // The menu's own padding: no option, no control. Whether the press's default was cancelled,
        // read after every handler ran (window, bubbling).
        await page.evaluate(() => {
          window.addEventListener("mousedown", (event) => {
            (window as unknown as { cancelled?: boolean }).cancelled = event.defaultPrevented;
          });
        });
        const at = (await menu.boundingBox())!;
        await page.mouse.move(at.x + 2, at.y + 2);
        await page.mouse.down();
        const cancelled = await page.evaluate(() => (window as unknown as { cancelled?: boolean }).cancelled);
        await page.mouse.up();
        expect(cancelled).toBe(false);
        await page.close();
      });

      test("the card's buttons keep their own presses", async () => {
        const page = await chat(browsers.get(name)!);
        // A press on a button (held, so its menu or action does not run) is the button's: the card
        // does not move the keyboard into the prompt under it.
        const buttons = page.locator(".acpmux-composer-box button:visible");
        expect(await buttons.count()).toBeGreaterThan(0);
        for (let index = 0; index < (await buttons.count()); index++) {
          const button = buttons.nth(index);
          const label = (await button.getAttribute("aria-label")) ?? (await button.innerText());
          const at = (await button.boundingBox())!;
          await blur(page);
          await page.mouse.move(at.x + at.width / 2, at.y + at.height / 2);
          await page.mouse.down();
          const focused = await inPrompt(page);
          // Release outside the button, so no click runs.
          await page.mouse.move(at.x + at.width / 2, 20);
          await page.mouse.up();
          expect({ label, focused }).toEqual({ label, focused: false });
        }
        await page.close();
      });
    });
});
