// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag starting in the bottom stack's blank strip or either side of the composer column must still
// select transcript text. The dedicated harness keeps this browser regression independent of other
// transcript fixtures that may add scroll behavior.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-bottom-gutter-select-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `transcript-bottom-gutter-select: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("bottom gutter select", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-bottom-gutter.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const rows = [
    { id: "m1", version: 1, at: 1_000, kind: "assistant", text: "Alpha keeper. The keeper climbed to the gallery." },
    { id: "m2", version: 1, at: 2_000, kind: "assistant", text: "Bravo tide. The tide came in under the jetty." },
    { id: "m3", version: 1, at: 3_000, kind: "assistant", text: "Charlie gull. A gull settled on the rail." },
  ];
  const open = async (name: string): Promise<Page> => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1280, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-bottom-gutter.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.waitForSelector('.acpmux-scroll .acpmux-row[data-row-id="m1"]');
    for (let left = 10; left > 0; left--) await page.evaluate(() => window.cmuxPaintFrame());
    await page.evaluate(() => (window as unknown as { __showBottomDock(): void }).__showBottomDock());
    await page.waitForSelector('[data-testid="bottom-selection-strip"]');
    for (let left = 6; left > 0; left--) await page.evaluate(() => window.cmuxPaintFrame());
    return page;
  };
  const selected = (page: Page) => page.evaluate(() => window.getSelection()?.toString() ?? "");
  const drag = async (page: Page, from: { x: number; y: number }, to: { x: number; y: number }) => {
    await page.mouse.move(from.x, from.y);
    await page.mouse.down();
    for (let step = 1; step <= 6; step += 1) {
      await page.mouse.move(from.x + ((to.x - from.x) * step) / 6, from.y + ((to.y - from.y) * step) / 6);
      await page.evaluate(() => window.cmuxPaintFrame());
    }
    await page.mouse.up();
  };

  for (const [name] of engines) {
    test(`${name}: bottom strip and both side gutters start a transcript selection`, async () => {
      const page = await open(name);
      const zones = await page.evaluate(() => {
        const strip = document
          .querySelector<HTMLElement>('[data-testid="bottom-selection-strip"]')!
          .getBoundingClientRect();
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const column = document.querySelector<HTMLElement>('.acpmux-row[data-row-id="m1"]')!.getBoundingClientRect();
        return {
          strip: { x: strip.left + 22, y: strip.top + strip.height / 2 },
          left: { x: column.left / 2, y: strip.top + strip.height / 2 },
          right: { x: (column.right + view.right) / 2, y: strip.top + strip.height / 2 },
          end: { x: column.left + 180, y: column.top + 4 },
        };
      });
      for (const [zone, from] of Object.entries({
        strip: zones.strip,
        "left gutter": zones.left,
        "right gutter": zones.right,
      })) {
        await drag(page, from, zones.end);
        expect(await selected(page), zone).toContain("Alpha keeper.");
        await page.evaluate(() => window.getSelection()?.removeAllRanges());
      }
      await page.close();
    });
  }
});
