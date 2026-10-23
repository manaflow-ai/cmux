// CodeRouter's provider and linked-account rows are one height: a row with a pill button was 37px
// and a row without one 31px, so the list's rules stepped. Rows hold one control's height whether or
// not they show one, and the pill buttons are the shared control height.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("coderouter-row-heights.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/src/pages/coderouter/index.html";
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

  test("provider and linked-account rows are one height, with or without a button", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 900 } });
    await page.goto(`http://127.0.0.1:${port}${PAGE}?mock`);
    await page.locator(".cr-provider").first().waitFor();
    const rows = await page.evaluate(() =>
      [...document.querySelectorAll(".cr-provider, .cr-linked-row")].map((row) => ({
        height: Math.round(row.getBoundingClientRect().height),
        buttons: row.querySelectorAll("button").length,
      })),
    );
    await page.close();
    // The mock has rows of both kinds, so the check compares them.
    expect(rows.some((row) => row.buttons > 0)).toBe(true);
    expect(rows.some((row) => row.buttons === 0)).toBe(true);
    expect(new Set(rows.map((row) => row.height)).size).toBe(1);
  });
});
