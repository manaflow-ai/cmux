// A closing fence moves nothing (StreamingCode.tsx): the plain card an open fence draws and the
// highlighted card that replaces it are the same height, in both engines the app uses. Pierre keeps
// a strip for its horizontal scrollbar under the code rows at all times, 6 px in WebKit and none in
// headless Chromium, so in WebKit the highlighted card came out 6 px taller than the plain one and
// the paragraphs under a code block moved down as its fence closed (streaming-text-frames.test.ts
// saw it as a 6 px layout shift in WebKit only). The page (browser/code-handoff-height.harness.tsx)
// draws both cards for the streaming reply's fence, a short one and a wide one, and reports their
// heights.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import type { FenceName, FenceReport } from "./browser/code-handoff-height.harness";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("code-handoff-height.test.ts", async () => {
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
      console.warn(`code-handoff-height: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("code handoff height", () => test("no engine", () => {}));
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
      // The dev server serves no built highlight worker (#25876): the page runs Pierre's own.
      plugins: [devHighlightWorker()],
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/code-handoff-height.html");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  test.each(engines.map(([name]) => name))(
    "%s: a fence's highlighted card is as tall as the plain card it replaces",
    async (name) => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/code-handoff-height.html`);
      await page.waitForFunction(() => "__codeHandoff" in window);
      const report = (await page.evaluate(() =>
        (window as unknown as { __codeHandoff: { measure(): Promise<unknown> } }).__codeHandoff.measure(),
      )) as Record<FenceName, FenceReport>;
      await page.close();
      console.log(`code-handoff-height ${name}: ${JSON.stringify(report)}`);
      for (const fence of Object.values(report)) expect(fence.highlighted).toEqual(fence.plain);
      // The wide fence's row still scrolls sideways, its scrollbar under the last line.
      expect(report.wide.scrolls).toBe(true);
    },
  );
});
