// l10n-allow-file: test assertions on the viewer's English labels, not shipped UI.
// The diff viewer's chrome in real Chromium (test/browser/diff-chrome.html), from the designer audit of the
// viewer (user 2026-11-19: "there's a lot of stuff we need to fix for diff viewer"):
// - the file header bar and the empty state ("No changes") follow Text Size (the host's
//   `--cmux-interface-scale`), as the rest of the chrome does, where they were fixed at 14 px;
// - the header bar's icon buttons (Viewed's eye, the collapse caret) round as every other button
//   (`--ds-radius-control`, the toolbar pill's buttons), where they had their own 5 px;
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("diff-chrome-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  if (!(await probeEngineOrSkip("diff-chrome-browser.test.ts", "chromium", chromium))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/diff-chrome.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A new page on the harness with `query`, once `ready` is drawn. */
  async function open(query: string, ready: string): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const context = await browser!.newContext({ viewport: { width: 900, height: 600 } });
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${port}/test/browser/diff-chrome.html${query}`);
    await page.locator(ready).first().waitFor();
    return page;
  }

  /** The drawn font size of `selector` at the host's Text Size `scale`. */
  function fontSizeAt(page: Page, selector: string, scale: number): Promise<string> {
    return page.evaluate(
      ([selector, scale]) => {
        document.documentElement.style.setProperty("--cmux-interface-scale", String(scale));
        return getComputedStyle(document.querySelector(selector as string)!).fontSize;
      },
      [selector, scale] as const,
    );
  }

  test("the file header bar follows Text Size", async () => {
    const page = await open("", ".file-header-name");
    try {
      expect(await fontSizeAt(page, ".file-header", 1)).toBe("14px");
      expect(await fontSizeAt(page, ".file-header", 1.25)).toBe("17.5px");
    } finally {
      await page.context().close();
    }
  });

  test("the empty state follows Text Size", async () => {
    const page = await open("?empty", 'body[data-status-only="true"] #status-text');
    try {
      expect(await page.locator("#status-text").textContent()).toBe("No changes");
      expect(await fontSizeAt(page, "#status", 1)).toBe("14px");
      expect(await fontSizeAt(page, "#status", 1.25)).toBe("17.5px");
    } finally {
      await page.context().close();
    }
  });

  test("the header bar's eye and caret round as the toolbar's buttons", async () => {
    const page = await open("", ".file-review-eye");
    try {
      const corners = (hostRadius: string | null) =>
        page.evaluate((hostRadius) => {
          const root = document.documentElement.style;
          if (hostRadius === null) root.removeProperty("--cmux-button-radius");
          else root.setProperty("--cmux-button-radius", hostRadius);
          const corner = (selector: string) => getComputedStyle(document.querySelector(selector)!).borderTopLeftRadius;
          return {
            button: corner(".diff-pill-button"),
            eye: corner(".file-review-eye"),
            caret: corner(".file-header-caret"),
          };
        }, hostRadius);
      const standalone = await corners(null);
      expect(standalone.eye).toBe(standalone.button);
      expect(standalone.caret).toBe(standalone.button);
      // The host's button corner (Metrics.buttonCornerRadius) reaches them too.
      expect(await corners("6px")).toEqual({ button: "6px", eye: "6px", caret: "6px" });
    } finally {
      await page.context().close();
    }
  });
});
