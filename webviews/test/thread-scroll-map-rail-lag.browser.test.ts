// l10n-allow-file: generated transcript rows are test fixtures, not shipped copy.
// The full-height prompt rail must move in the same painted frame as a RAF-driven transcript scroll.
// This reproduces the reported rail lag while a long reply keeps streaming, in both browser engines.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import path from "node:path";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("thread-scroll-map-rail-lag.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/thread-minimap.html?layout=full");
    for (const [name, engine] of Object.entries({ chromium, webkit })) {
      try {
        browsers.set(name, await (engine as BrowserType).launch({ headless: true }));
      } catch {
        // The shared webview lane reports a missing engine through this file's result.
        throw new Error(`${name} did not launch (install its Playwright engine)`);
      }
    }
  });

  afterAll(async () => {
    await Promise.all([...browsers.values()].map((browser) => browser.close()));
    await vite?.close();
  });

  const rows = Array.from({ length: 160 }, (_, index) => [
    { id: `user-${index + 1}`, kind: "user", text: `Question ${index + 1}`, version: 1, at: index + 1 },
    {
      id: `reply-${index}`,
      kind: "assistant",
      text: `Answer ${index + 1}.\n\nA long streamed paragraph keeps the transcript growing while the reader scrolls.`,
      version: 1,
      at: index + 1,
    },
    { id: `summary-${index}`, kind: "turnSummary", status: "completed", durationMs: 1_000, version: 1, at: index + 1 },
  ]).flat();

  for (const [name, browser] of browsers) {
    test(`${name}: the rail thumb has no same-frame lag during a streamed scroll`, async () => {
      const port = (vite.httpServer!.address() as { port: number }).port;
      const page = await browser.newPage({ viewport: { width: 1280, height: 820 } });
      try {
        await page.goto(`http://127.0.0.1:${port}/test/browser/thread-minimap.html?layout=full`);
        await page.waitForFunction(() => "__showRows" in window);
        await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown[]): void }).__showRows(shown), rows);
        await page.waitForSelector(".acpmux-scrollmap__view");
        const samples = await page.evaluate(async (initialRows) => {
          const show = (window as unknown as { __showRows(rows: unknown[]): void }).__showRows;
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const rail = document.querySelector<HTMLElement>(".acpmux-scrollmap")!;
          const thumb = document.querySelector<HTMLElement>(".acpmux-scrollmap__view")!;
          const parseY = () => {
            const transform = getComputedStyle(thumb).transform;
            if (transform === "none") return 0;
            return new DOMMatrixReadOnly(transform).m42;
          };
          const expected = () => {
            const total = Number.parseFloat(document.querySelector<HTMLElement>(".acpmux-spacer")?.style.height ?? "0");
            const span = total + 16;
            const height = rail.clientHeight;
            const size = Math.min(height, Math.max(18, (node.clientHeight / span) * height));
            return { top: Math.max(0, Math.min(height - size, (Math.max(0, node.scrollTop) / span) * height)), size };
          };
          const start = Math.max(0, node.scrollHeight - node.clientHeight) * 0.78;
          node.scrollTop = start;
          node.dispatchEvent(new Event("scroll"));
          await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
          const records: { frame: number; error: number }[] = [];
          for (let frame = 0; frame < 72; frame += 1) {
            const max = Math.max(0, node.scrollHeight - node.clientHeight);
            node.scrollTop = Math.max(0, start - (max * 0.66 * (frame + 1)) / 72);
            // This is the event emitted by scrollMotion immediately after its RAF write.
            node.dispatchEvent(new Event("acpmux-motion-scroll"));
            const target = expected();
            records.push({ frame, error: Math.abs(parseY() - target.top) });
            if (frame % 4 === 0) {
              const streamed = (initialRows as Array<Record<string, unknown>>).map((row) =>
                row.id === "reply-159"
                  ? { ...row, text: `${String(row.text)}\nstream chunk ${frame}` }
                  : row,
              );
              show(streamed);
            }
            await new Promise<void>((resolve) => requestAnimationFrame(() => resolve()));
          }
          return records;
        }, rows);
        const lagFrames = samples.map((sample) => (sample.error > 0.75 ? 1 : 0));
        const sorted = [...lagFrames].sort((a, b) => a - b);
        const percentile = (p: number) => sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * p) - 1)]!;
        const metrics = { samples: samples.length, p50: percentile(0.5), p95: percentile(0.95), maxError: Math.max(...samples.map((s) => s.error)) };
        console.log(`thread-scroll-map-rail-lag ${name}: ${JSON.stringify(metrics)}`);
        expect(metrics.p95).toBe(0);
      } finally {
        await page.close();
      }
    }, 120_000);
  }
});
