// Temporary (not committed): renders agent-pane.blank-load-fade settled and mid-fade, for a before/after.
import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

const out = process.argv[2]!;
fs.mkdirSync(out, { recursive: true });
const vite = await createServer({
  configFile: path.resolve("vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const origin = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
const browser = await chromium.launch({ executablePath: process.env.CHROME ?? "/usr/bin/google-chrome-stable" });
for (let attempt = 1; ; attempt++) {
  try {
    await warmGalleryFrame(vite, "agent-pane.blank-load-fade", { browser, params: { variant: "micro" }, timeoutMs: 180_000 });
    break;
  } catch (error) {
    console.log(`warm attempt ${attempt}: ${String(error).split("\n")[0]}`);
    if (attempt >= 4) throw error;
  }
}
const READ = '[data-blank-load-fade] [data-row-id="load-user-1"]';
const summary = () =>
  [...document.querySelectorAll<HTMLElement>("[data-blank-load-fade] [data-row-id]")].map((row) => {
    const box = row.getBoundingClientRect();
    return `${row.dataset.rowId} top=${Math.round(box.top)} h=${Math.round(box.height)} op=${getComputedStyle(row).opacity} cls=${row.className}`;
  });
const report: Record<string, unknown> = {};
for (const variant of ["micro", "standard", "large", "linear", "stagger", "pop", "micro-mid"]) {
  for (const mode of ["settled", "mid"]) {
    const page = await browser.newPage({ viewport: { width: 1600, height: 1000 }, deviceScaleFactor: 1 });
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(String(error)));
    if (mode === "mid") {
      // Freeze every animation at 50 ms into it, on the frame the read's rows land.
      await page.addInitScript((read) => {
        const tick = () => {
          if (document.querySelector(read)) {
            for (const animation of document.getAnimations()) {
              animation.pause();
              animation.currentTime = 50;
            }
            (window as unknown as { __frozen: boolean }).__frozen = true;
            return;
          }
          requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      }, READ);
    }
    await page.goto(origin + galleryFrame("agent-pane.blank-load-fade", { variant }), { waitUntil: "load" });
    await page.waitForSelector(READ, { timeout: 30_000 });
    let stuck: string[] = [];
    if (mode === "mid") {
      if (variant !== "micro-mid") await page.waitForFunction(() => (window as unknown as { __frozen?: boolean }).__frozen);
      await page.waitForTimeout(300);
    } else {
      const ended = await page
        .waitForFunction(
          () => document.getAnimations().every((a) => a.playState === "finished" || a.playState === "idle"),
          null,
          { timeout: 5_000 },
        )
        .then(() => true)
        .catch(() => false);
      if (!ended)
        stuck = await page.evaluate(() =>
          document
            .getAnimations()
            .filter((a) => a.playState !== "finished")
            .map((a) => `${(a as CSSAnimation).animationName ?? a.id} ${a.playState} t=${a.currentTime} on ${(a.effect as KeyframeEffect)?.target?.className}`),
        );
      await page.evaluate(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))));
    }
    const rows = await page.evaluate(summary);
    const anims = await page.evaluate(() =>
      document.getAnimations().map((a) => `${(a as CSSAnimation).animationName ?? a.id} ${a.playState} t=${a.currentTime}`),
    );
    await page.screenshot({ path: path.join(out, `${variant}-${mode}.png`) });
    report[`${variant}-${mode}`] = { rows, anims, stuck, errors };
    await page.close();
  }
}
fs.writeFileSync(path.join(out, "report.json"), JSON.stringify(report, null, 1));
await browser.close();
await vite.close();
console.log("done", out);
