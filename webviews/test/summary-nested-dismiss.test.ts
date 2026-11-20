// cmux-web-test-timeout: 240
// Course item 12: closing the Sources menu must leave its floating Summary card open.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("summary-nested-dismiss.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const browsers = new Map<string, Browser>();
  let vite: Awaited<ReturnType<typeof createServer>>;
  const entry = "agent-pane.summary-card";
  const variant = "nested-sources-menu";
  const card = '.acpmux-summary-card[data-placement="popover"][data-presence="shown"]';
  const menu = '.acpmux-summary-menu[role="menu"]:not([data-ending-style])';

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const engine of [chromium, webkit]) {
      if (await probeEngineOrSkip("summary nested dismissal", engine.name(), engine))
        browsers.set(engine.name(), await engine.launch({ headless: true }));
    }
    expect(browsers.size).toBeGreaterThan(0);
    await warmGalleryFrame(vite, entry, { browser: browsers.values().next().value, params: { variant } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(browser: Browser, theme: string): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 760, height: 560 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant, frame: "component", width: 760, theme })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(card).waitFor();
    await page.locator('[data-menu="summary-sources-add"]').click();
    await page.locator(menu).waitFor();
    return page;
  }

  for (const theme of ["Catppuccin Mocha", "Catppuccin Latte"]) {
    for (const action of ["outside", "escape", "pick"] as const) {
      test(`Sources ${action} keeps Summary open (${theme})`, async () => {
        for (const [engine, browser] of browsers) {
          const page = await open(browser, theme);
          try {
            if (action === "outside") {
              // The card sits at the trailing edge; the empty leading corner is outside both layers.
              expect(
                await page.evaluate(
                  () => document.elementFromPoint(8, 8)?.closest(".acpmux-summary-card, .acpmux-summary-menu") === null,
                ),
              ).toBe(true);
              await page.mouse.click(8, 8);
            } else if (action === "escape") {
              await page.keyboard.press("Escape");
            } else {
              await page.locator(menu).getByRole("menuitem", { name: "Attach files or folders" }).click();
            }
            await page.locator(menu).waitFor({ state: "hidden" });
            if (process.env.CMUX_CAPTURE_DIR) {
              // Capture the settled result, including the baseline's incorrectly dismissed card.
              await page.locator('.acpmux-summary-menu[role="menu"]').waitFor({ state: "hidden" });
              if ((await page.locator(card).count()) === 0)
                await page.locator('.acpmux-summary-card[data-placement="popover"]').waitFor({ state: "hidden" });
              await mkdir(process.env.CMUX_CAPTURE_DIR, { recursive: true });
              await page.screenshot({
                type: "jpeg",
                quality: 45,
                // Keep the evidence focused on the nested layers and small enough for the
                // broker receipt; the full gallery frame is still available from the test route.
                clip: { x: 440, y: 24, width: 310, height: 180 },
                path: path.join(
                  process.env.CMUX_CAPTURE_DIR,
                  `summary-${engine}-${theme.replaceAll(" ", "-")}-${action}.jpg`,
                ),
              });
            }
            expect(await page.locator(card).count()).toBe(1);
            // Once the child is gone, the next outside press dismisses the card itself.
            await page.mouse.click(8, 8);
            await page.locator(card).waitFor({ state: "hidden" });
          } finally {
            await page.close();
          }
        }
      });
    }
  }
});
