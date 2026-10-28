// cmux-web-test-timeout: 180
// l10n-allow-file: deterministic transcript fixture, not shipped UI.
// A 192,000-event transcript must not make periodic client snapshots walk the whole event history.
// The browser harness drives AcpmuxDirectClient.replay and turnViewFrom, then reports each tick's
// frame/task counts and long tasks at that same fixture size.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import type { LongTaskQueueReport } from "./browser/long-task-queue.harness";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import path from "node:path";

await requireBrowserLane("long-task-queue.test.ts", async () => {
  setDefaultTimeout(180_000);
  let browser: Browser | undefined;
  try {
    browser = await chromium.launch({ headless: true });
  } catch {
    console.warn("long-task-queue: skipping (run `bunx playwright install chromium`)");
    describe.skip("long transcript periodic tick", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const vite = await createServer({
    root: webviews,
    configFile: path.join(webviews, "vite.config.ts"),
    server: { port: 0, host: "127.0.0.1", strictPort: false },
    logLevel: "error",
  });
  await vite.listen();
  await warmViteServer(vite, "/test/browser/long-task-queue.html");
  const { port } = vite.httpServer!.address() as { port: number };
  afterAll(async () => {
    await browser?.close();
    await vite.close();
  });

  test("keeps a 192,000-event periodic snapshot under the frame budget and reports frames/tasks", async () => {
    const page = await browser!.newPage({
      viewport: { width: 900, height: 640 },
    });
    try {
      await page.goto(`http://127.0.0.1:${port}/test/browser/long-task-queue.html`);
      await page.waitForFunction(() => "__longTaskQueue" in window);
      const report = (await page.evaluate(() => window.__longTaskQueue.run())) as LongTaskQueueReport;
      console.log(`long-task-queue: ${JSON.stringify(report)}`);
      expect(report.eventCount).toBe(192_000);
      expect(report.rowCount).toBe(192_000);
      expect(report.ticks).toBe(12);
      expect(report.freshSnapshots).toBe(0);
      expect(report.tasks).toBeGreaterThan(report.ticks);
      expect(report.tickTasks.every((count) => count > 0)).toBe(true);
      expect(report.tickRowReads.every((count) => count < report.eventCount / 100)).toBe(true);
      expect(report.maxTickMs).toBeLessThan(16.7);
      expect(report.tickFrames.every((count) => count > 0)).toBe(true);
      expect(report.longTasks.filter((task) => task.duration >= 50)).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
