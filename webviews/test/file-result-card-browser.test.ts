// A read's card (FileResultCard.tsx) is drawn with the diff card's classes (`.cv-edit-diff`), whose lengths are the
// custom properties editDiffBox.ts puts on the card (`--cv-edit-diff-*`). The read card sets them too: without
// them its header's `min-height` was invalid and the header shrank from 32 px to its 20 px line (architect review
// of #46650). Here the card's header is as tall as the diff card's head at the default chat text size and at a
// larger one (`--cv-font-size` × 32 / 14).
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("file-result-card-browser.test.ts", async () => {
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
      console.warn(`file-result-card-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("file result card", () => test("no engine", () => {}));
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
    await warmViteServer(vite, "/test/browser/file-result-card.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  test.each(engines.map(([name]) => name))("%s: a read card's header is the diff card's head", async (name) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/file-result-card.html`);
    await page.waitForFunction(() => "__fileResultCard" in window);
    const measure = (size: number) =>
      page.evaluate(
        (s) =>
          (window as unknown as { __fileResultCard: { measure(size: number): number } }).__fileResultCard.measure(s),
        size,
      );
    const atDefault = await measure(14);
    const atLarger = await measure(18);
    await page.close();
    console.log(`file-result-card ${name}: header ${atDefault} px at 14 px text, ${atLarger} px at 18 px`);
    expect(atDefault).toBeCloseTo(32, 1);
    expect(atLarger).toBeCloseTo((18 * 32) / 14, 1);
  });
});
