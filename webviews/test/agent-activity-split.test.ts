// The Agent Activity page's split view in a narrow pane (480 px, the gallery's narrow width): the
// selected agent's title stays on one line beside its status, and Stop, Pause and Watch all stay
// on screen (they wrap under the title when the header runs out of room) instead of the title
// wrapping one word per line and Watch running off the edge. The toolbar's layout picker stays on
// screen too, because its search field gives up width first. The session list gives up width to
// the detail first. At the normal width the header is one line.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-activity-split.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/test/browser/agent-activity-split.html";
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
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [480, 1000]) {
    test(`at ${width} px the detail header keeps its title on one line and its actions on screen`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width, height: 560 } });
      await page.goto(`http://127.0.0.1:${port}${PAGE}`);
      await page.locator(".detail header .actions button").first().waitFor();
      const m = await page.evaluate(() => {
        const header = document.querySelector(".detail header")!;
        const title = header.querySelector("strong")!;
        // One line: the title's box is no taller than one of its line boxes.
        const range = document.createRange();
        range.selectNodeContents(title);
        const lineTops = new Set([...range.getClientRects()].map((r) => Math.round(r.top)));
        const buttons = [...header.querySelectorAll(".actions button")].map((b) => b.getBoundingClientRect());
        return {
          titleLines: lineTops.size,
          buttonsRight: Math.max(...buttons.map((b) => b.right)),
          // The segments, not the fieldset: the fieldset shrinks and lets its segments overflow it.
          layoutPickerRight: Math.max(
            ...[...document.querySelectorAll("nav .segment")].map((s) => s.getBoundingClientRect().right),
          ),
          headerLines: new Set([...header.children].map((c) => Math.round(c.getBoundingClientRect().top / 8))).size,
        };
      });
      await page.close();
      expect(m.titleLines).toBe(1);
      expect(m.buttonsRight).toBeLessThanOrEqual(width);
      expect(m.layoutPickerRight).toBeLessThanOrEqual(width);
      if (width >= 1000) expect(m.headerLines).toBe(1);
    });
  }
});
