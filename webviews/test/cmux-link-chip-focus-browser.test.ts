// l10n-allow-file: browser fixture prompts, not shipped UI.
// A cmux link tabbed to before the page names it keeps the focus when its answer comes (review of
// #38166): the link and its chip are different elements (chips/CmuxLinkChip.tsx), and the chip that
// replaces the link takes the focus, so Enter still opens it, as a URL chip that resolves in place
// does. Both fallbacks: an app link's plain anchor and cmux.com's agent link's URL chip.
//
// Real Chromium from Playwright: Tab and Enter move a real focus.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/cmux-link-chip-focus-browser.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { build } from "esbuild";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("cmux-link-chip-focus-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("cmux-link-chip-focus-browser", "chromium", chromium))) return;
  setDefaultTimeout(120_000);
  const SESSION = "9b2f4c1e-5d7a-4e3b-8c6f-1a2b3c4d5e6f";
  const AGENT = `cmux://agent/claude/${SESSION}`;
  const WEB_AGENT = `https://cmux.com/deeplink/agent?harness=claude&session=${SESSION}`;
  const TITLE = "Review the retry fix";
  let browser: Browser;
  let page: Page;
  let bundle: string;

  beforeAll(async () => {
    const webviews = path.resolve(import.meta.dir, "..");
    const built = await build({
      stdin: {
        contents: [
          'import { createElement } from "react";',
          'import { createRoot } from "react-dom/client";',
          'import { flushSync } from "react-dom";',
          'import { PromptTyped } from "./src/agent-session/acpmux/conversation/PromptText";',
          'import { SessionHoverStore } from "./src/agent-session/acpmux/started/sessionHover";',
          'import { SessionHoverContext } from "./src/agent-session/acpmux/started/sessionHoverCardModel";',
          "let root;",
          "window.chipHarness = {",
          "  mount(text) {",
          "    const store = new SessionHoverStore();",
          "    window.chipHarness.store = store;",
          "    root?.unmount();",
          '    root = createRoot(document.getElementById("root"));',
          "    flushSync(() => root.render(createElement(SessionHoverContext.Provider, { value: { store, open() {} } },",
          "      createElement(PromptTyped, { text, show: (shown) => shown }))));",
          "  },",
          "};",
        ].join("\n"),
        resolveDir: webviews,
        loader: "tsx",
      },
      bundle: true,
      format: "iife",
      platform: "browser",
      jsx: "automatic",
      define: { "process.env.NODE_ENV": '"development"' },
      loader: { ".css": "empty", ".svg": "text", ".woff2": "empty", ".png": "empty", ".json": "json" },
      write: false,
      logLevel: "silent",
    });
    bundle = built.outputFiles[0]!.text;
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage();
    await page.setContent(`<!doctype html><body><button id="before">before</button><div id="root"></div></body>`);
    await page.addScriptTag({ content: bundle });
    // Enter's click on a link, kept from navigating.
    await page.evaluate(() => {
      const clicks: string[] = [];
      Object.assign(window, { clicks });
      document.addEventListener("click", (event) => {
        const link = (event.target as Element).closest("a");
        clicks.push(link?.getAttribute("data-cmux-link") ?? link?.className ?? "");
        event.preventDefault();
      });
    });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const [name, link] of [
    ["an app agent link", AGENT],
    ["cmux.com's agent link", WEB_AGENT],
  ] as const)
    test(`${name} tabbed to before it resolves keeps the focus as its chip, and Enter opens it`, async () => {
      await page.evaluate((text) => (window as any).chipHarness.mount(text), `Ask ${link}`);
      await page.focus("#before");
      await page.keyboard.press("Tab");
      expect(await page.evaluate(() => document.activeElement?.getAttribute("href"))).toBe(link);
      expect(await page.evaluate(() => document.querySelector("[data-cmux-link]"))).toBeNull();
      // The list names the chat later, in its own task, with the focus already on the link.
      await page.evaluate(
        ({ session, title }) =>
          (window as any).chipHarness.store.set([
            { sessionId: "acp-reviewer", harness: "claude", agentSessionId: session, title },
          ]),
        { session: SESSION, title: TITLE },
      );
      await page.waitForSelector("[data-cmux-link=chat]");
      const focused = await page.evaluate(() => {
        const active = document.activeElement;
        return [active?.getAttribute("data-cmux-link"), active?.querySelector(".cv-cmux-link__title")?.textContent];
      });
      expect(focused).toEqual(["chat", TITLE]);
      await page.evaluate(() => ((window as any).clicks.length = 0));
      await page.keyboard.press("Enter");
      expect(await page.evaluate(() => (window as any).clicks)).toEqual(["chat"]);
    });
});
