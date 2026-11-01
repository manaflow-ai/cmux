// The New Tab page's field takes the keyboard back when its page does, as the chat composer does
// (composerFocus.ts). A press on the page's background leaves nothing focused; switch to another
// tab or pane and back, and the page got the keyboard with nothing in it: no caret, and Backspace,
// the arrows or Cmd-V went nowhere (only printed keys reached the field, through type-anywhere).
// The page now gives an idle keyboard to its field when the window takes focus (WebKit's signal for
// its web view becoming first responder); a field or menu that has focus keeps it.
//
// The real agent pane (vite.config.acpmux-pane.mjs) as a New Tab page, with a stand-in host and the
// in-page mock transport. Chromium and WebKit; CI fails the file when it cannot launch them
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-field-reclaims-keyboard.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-field-reclaims-keyboard.test.ts", async () => {
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
      console.warn(`new-tab-field-reclaims-keyboard: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("New Tab field reclaims the keyboard", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  // Cards: its chat cards and All Chats button are what the field takes the keyboard back from.
  const context = {
    kind: "agent",
    hotkeys: {},
    home: HOME,
    projects: [`${HOME}/src/atlas`],
    host: "cosmic-gray",
    template: "cards",
  };
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

  async function newTab(browser: Browser): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((newTab) => {
      const w = window as unknown as Record<string, unknown>;
      w.__cmuxNewTabContext = newTab;
      w.webkit = { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } };
      w.cmuxAcpmuxActions = {
        ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
      };
    }, context);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".nt-field").waitFor();
    // The field is the composer's Markdown prompt: its editable element, inside `.nt-field`, has focus.
    await page.waitForFunction(() => document.activeElement?.closest(".nt-field") != null);
    return page;
  }

  /// The pane's web view resigns first responder and gets it back (a tab or pane switch away and back).
  const switchAwayAndBack = (page: Page) =>
    page.evaluate(async () => {
      window.dispatchEvent(new Event("blur"));
      await new Promise((resolve) => requestAnimationFrame(resolve));
      window.dispatchEvent(new Event("focus"));
      await new Promise((resolve) => requestAnimationFrame(resolve));
    });
  const focused = (page: Page) =>
    page.evaluate(() => {
      const active = document.activeElement;
      if (!active || active === document.body) return "body";
      // The field's editable element is inside `.nt-field` (MarkdownField).
      return active.closest(".nt-field") ? "nt-field" : active.className.split(/\s+/)[0];
    });
  const fieldText = (page: Page) =>
    page.evaluate(() => {
      const field = document.querySelector(".nt-field") as
        | (Element & { acpmuxMarkdownField?: { text(): { value: string } } })
        | null;
      return field?.acpmuxMarkdownField?.text().value;
    });

  for (const [name] of engines)
    describe(name, () => {
      test("after a press on the background, switching back gives the field the keyboard", async () => {
        const page = await newTab(browsers.get(name)!);
        await page.keyboard.type("fix the build");
        // A press on the page's background: nothing on the page has focus.
        await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
        expect(await focused(page)).toBe("body");
        await switchAwayAndBack(page);
        expect(await focused(page)).toBe("nt-field");
        // A named key reaches the field, and the draft was not selected (a typed key would replace it).
        await page.keyboard.press("Backspace");
        expect(await fieldText(page)).toBe("fix the buil");
        await page.close();
      });

      test("taking the keyboard back keeps where the page was scrolled", async () => {
        const page = await newTab(browsers.get(name)!);
        await page.setViewportSize({ width: 900, height: 300 });
        const scrolled = await page.evaluate(() => {
          const screen = document.querySelector<HTMLElement>(".nt-screen")!;
          screen.scrollTop = screen.scrollHeight;
          (document.activeElement as HTMLElement | null)?.blur();
          return screen.scrollTop;
        });
        expect(scrolled).toBeGreaterThan(0);
        await switchAwayAndBack(page);
        expect(await focused(page)).toBe("nt-field");
        expect(await page.evaluate(() => document.querySelector<HTMLElement>(".nt-screen")!.scrollTop)).toBe(scrolled);
        await page.close();
      });

      test("a control that has focus keeps it when the page gets the keyboard back", async () => {
        const page = await newTab(browsers.get(name)!);
        await page.keyboard.type("fix");
        await page.locator(".nt-screen button.nt-chats-all").focus();
        await switchAwayAndBack(page);
        expect(await focused(page)).toBe("nt-chats-all");
        expect(await fieldText(page)).toBe("fix");
        await page.close();
      });
    });
});
