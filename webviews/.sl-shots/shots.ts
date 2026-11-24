// Screenshots of the started line harness: one subagent, then two, at 640 and 360 px, with the
// pointer resting where the first chip appears. Usage: bun shots.ts OUTDIR LABEL
import path from "node:path";
import { chromium } from "playwright";
const [out, label] = process.argv.slice(2);
const root = path.resolve(".");
const { createServer } = await import("vite");
const vite = await createServer({ root, configFile: path.join(root, "vite.config.ts"), server: { port: 0, host: "127.0.0.1" }, logLevel: "error" });
await vite.listen();
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 700, height: 70 }, deviceScaleFactor: 2 });
const port = vite.httpServer.address().port;
await page.goto(`http://127.0.0.1:${port}/test/browser/started-line-no-jump.html`);
await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true", undefined, { timeout: 90_000 });
for (const width of [640, 360]) {
  await page.evaluate((w) => (window as any).show(1, w), width);
  const box = (await page.locator(".cv-subagent-started__name").first().boundingBox())!;
  await page.evaluate((w) => (window as any).show(0, w), width);
  await page.mouse.move(box.x + 20, box.y + box.height / 2);
  for (const count of [1, 2]) {
    await page.evaluate(([c, w]) => (window as any).show(c, w), [count, width]);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/${label}-${width}px-${count}.png` });
  }
}
await browser.close();
await vite.close();
