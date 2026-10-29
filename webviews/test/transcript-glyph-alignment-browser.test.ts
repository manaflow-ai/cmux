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
        const text = row.querySelector<HTMLElement>(".cv-tool__text, .cv-worked__label, .cv-received__name, .acpmux-chat-inspector-row__name");
        const glyphs = [...row.querySelectorAll<HTMLElement>(".cv-tool__icon svg, .cv-command__ok, .cv-command__time, .cv-tool__chevron svg, .cv-worked__chevron, .cv-received__icon svg, .acpmux-row-glyph")];
        if (!glyphs.length) throw new Error(`missing glyph for ${row.dataset.glyphRow}`);
        const lineBox = (text ?? row).getBoundingClientRect();
        const lineCenter = (lineBox.top + lineBox.bottom) / 2;
        return { kind: row.dataset.glyphRow, deltas: glyphs.map((glyph) => { const box = glyph.getBoundingClientRect(); return Math.abs(lineCenter - (box.top + box.bottom) / 2); }) };
      }),
    );

  const measureFooter = async (page: Page) =>
    page.evaluate(() => {
      const time = document.querySelector<HTMLElement>("[data-footer-row] .cv-message-footer-row .cv-user__time")!;
      const timeBox = time.getBoundingClientRect();
      const center = (box: DOMRect) => (box.top + box.bottom) / 2;
      return [...document.querySelectorAll<SVGElement>("[data-footer-row] .cv-message-footer-row .cv-iconbtn svg")].map((glyph) => ({
        kind: glyph.parentElement?.getAttribute("aria-label") ?? "action",
        delta: Math.abs(center(glyph.getBoundingClientRect()) - center(timeBox)),
      }));
    });

  for (const theme of ["dark", "light"] as const) {
    for (const height of [28, 40] as const) {
      test(`${theme} ${height}px rows keep every glyph on the center line`, async () => {
        const port = (vite!.httpServer!.address() as { port: number }).port;
        const page = await browser!.newPage({ viewport: { width: 680, height: 320 } });
        // Add `capture=before` when collecting the synthetic baseline alongside this after-state capture.
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-glyph-alignment.html?theme=${theme}&height=${height}&capture=after`);
        await page.locator("[data-glyph-row]").first().waitFor();
        await page.locator('[data-glyph-row="tool"]').hover();
        const rows = await measure(page);
        expect(rows).toHaveLength(4);
        for (const row of rows) for (const delta of row.deltas) expect(delta, `${theme}/${height}/${row.kind}`).toBeLessThanOrEqual(0.5);
        const footer = await measureFooter(page);
        expect(footer).toHaveLength(3);
        for (const glyph of footer) expect(glyph.delta, `${theme}/${height}/footer/${glyph.kind}`).toBeLessThanOrEqual(0.5);
        await page.close();
      });
    }
  }
});
