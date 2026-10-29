// Synthetic, privacy-safe geometry fixture for the shared transcript/Session Info glyph slot.
// Leo's ask names the tool rows, "Worked for", "Received N" and peer-card secondary tone; this
// test keeps those labels synthetic while checking the shared 16px slot at both row rhythms.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-glyph-alignment-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("transcript glyph alignment", () => test("chromium", () => {}));
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
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
    await warmViteServer(vite, "/test/browser/transcript-glyph-alignment.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const measure = async (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("[data-glyph-row]")].map((row) => {
        const rowBox = row.getBoundingClientRect();
        const glyph = row.querySelector<HTMLElement>(".cv-tool__icon, .cv-worked__glyph, .cv-received__icon, .acpmux-row-glyph");
        if (!glyph) throw new Error(`missing glyph for ${row.dataset.glyphRow}`);
        const glyphBox = glyph.getBoundingClientRect();
        return { kind: row.dataset.glyphRow, delta: Math.abs((rowBox.top + rowBox.bottom) / 2 - (glyphBox.top + glyphBox.bottom) / 2) };
      }),
    );

  for (const theme of ["dark", "light"] as const) {
    for (const height of [28, 40] as const) {
      test(`${theme} ${height}px rows keep every glyph on the center line`, async () => {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        const page = await browser!.newPage({ viewport: { width: 680, height: 320 } });
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}&height=${height}`);
        await page.locator("[data-glyph-row]").first().waitFor();
        const rows = await measure(page);
        expect(rows).toHaveLength(4);
        for (const row of rows) expect(row.delta, `${theme}/${height}/${row.kind}`).toBeLessThanOrEqual(0.5);
        await page.close();
      });
    }
  }
});
