// l10n-allow-file: test fixtures.
// A ticking clock in a line's words sits on their baseline, and so does the line's button: Leo,
// 2026-11-21, on "Waiting for the agent service (1:07)  Restart agent service": "the time is not
// aligned with the rest of the shit", "the \"restart agent service\" isn't aligned either". The
// clock's reserved width was a hidden line under the time, which made that empty line the clock's
// baseline and lifted the time 3 px (Chromium) to 3.5 px (WebKit) above the words, and the taller
// line moved the button off them too (ui/typography.css). Real Chromium and WebKit on the pane's
// CSS (browser/typography-baseline.html).
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// What a row measures: the bottoms of the words' glyph box, the clock's and the button's, in CSS px.
type Row = { words: number; clock: number; button: number | null; lineHeight: number };

function measure(testId: string): Row {
  const row = document.querySelector(`[data-testid="${testId}"] .acpmux-host-line`)!;
  const message = row.querySelector(".acpmux-host-line-message")!;
  const clock = message.querySelector(".ui-clock")!;
  const button = row.querySelector("button");
  const bottom = (node: Node) => {
    const range = document.createRange();
    range.selectNodeContents(node);
    const rects = [...range.getClientRects()];
    return rects[rects.length - 1]!.bottom;
  };
  const words = [...message.childNodes].find((node) => node.nodeType === Node.TEXT_NODE && node.textContent!.trim())!;
  return {
    words: bottom(words),
    clock: bottom(clock.firstChild!),
    button: button ? bottom(button.firstChild ?? button) : null,
    lineHeight: row.getBoundingClientRect().height,
  };
}

await requireBrowserLane("typography-baseline-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  const vite = await createServer({
    root,
    configFile: path.join(root, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1" },
    logLevel: "error",
  });
  await vite.listen();
  await warmViteServer(vite, "/test/browser/typography-baseline.html");
  const port = (vite.httpServer!.address() as { port: number }).port;
  const browsers: Browser[] = [];
  afterAll(async () => {
    await Promise.all(browsers.map((browser) => browser.close()));
    await vite.close();
  });

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as const) {
    describe(`a clock in a line's words (${name})`, () => {
      let page: Page;
      const open = async () => {
        if (page) return page;
        const browser = await engine.launch({ headless: true });
        browsers.push(browser);
        page = await browser.newPage({ viewport: { width: 800, height: 400 } });
        await page.goto(`http://127.0.0.1:${port}/test/browser/typography-baseline.html`);
        await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
        return page;
      };

      for (const testId of ["waiting", "restoring", "fork"]) {
        test(`the ${testId} line's time sits on its words' baseline`, async () => {
          const row = await (await open()).evaluate(measure, testId);
          expect(Math.abs(row.clock - row.words)).toBeLessThan(0.5);
          if (row.button !== null) expect(Math.abs(row.button - row.words)).toBeLessThan(0.5);
          // The row keeps its one height (design/agent-host-line.md: at least a button's 24 px).
          expect(row.lineHeight).toBeLessThanOrEqual(24);
        });
      }
    });
  }
});
