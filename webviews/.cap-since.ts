// Temporary capture script (untracked): renders agent-pane.since-divider variants at several widths.
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "./test/support/galleryFrame";
const out = process.argv[2]!;
const variants = (
  process.argv[3] ?? "line-worked,line-worked-tokens,line-worked-uncounted,line-working,line-task"
).split(",");
const widths = [640, 420, 360, 300, 240, 200, 160];
const vite = await createServer({
  configFile: path.resolve("vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true, executablePath: "/usr/bin/google-chrome" });
for (const variant of variants)
  for (const width of widths) {
    const page = await browser.newPage({
      viewport: { width, height: 240 },
      reducedMotion: "reduce",
      deviceScaleFactor: 2,
    });
    try {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.since-divider", { variant })}`, {
        timeout: 120_000,
      });
      await page.locator(".cv-worked, .cv-task-line").first().waitFor({ timeout: 120_000 });
      await page.waitForTimeout(400);
      const info = await page.evaluate(() => {
        const tag = document.querySelector(".cv-since__tag");
        const worked = document.querySelector(".cv-worked, .cv-task-line");
        const r = (e: Element | null) => (e ? e.getBoundingClientRect() : null);
        const vis = [...document.querySelectorAll(".cv-since__tag > span")].map(
          (s) => `${s.className}:${getComputedStyle(s).opacity}`,
        );
        const label = document.querySelector(".cv-worked__count, .cv-worked__label");
        return {
          tag: r(tag),
          tagOpacity: tag && getComputedStyle(tag).opacity,
          worked: r(worked),
          wordsEnd: label ? r(label)!.right : null,
          vis,
        };
      });
      console.log(variant, width, JSON.stringify(info));
      await page.screenshot({ path: `${out}/${variant}-${width}.png`, clip: { x: 0, y: 0, width, height: 140 } });
    } catch (e) {
      console.log(variant, width, "ERR", String(e).slice(0, 200));
    } finally {
      await page.close();
    }
  }
await browser.close();
await vite.close();
