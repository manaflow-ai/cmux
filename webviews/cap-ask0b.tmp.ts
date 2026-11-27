// Scratch capture for ask-0b971a8f69 (not committed): the dwell gallery's arms, and a queued
// prompt row hovered for 120 ms with the reveal at 400 ms (before) and 240 ms (after).
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "./test/support/galleryFrame";

const out = process.argv[2] ?? "/tmp/ask0b/shots";
await mkdir(out, { recursive: true });
const vite = await createServer({
  configFile: path.join(import.meta.dir, "vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1", strictPort: false },
  logLevel: "error",
});
await vite.listen();
const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
const browser = await chromium.launch({ headless: true });
const ready = (page: import("playwright").Page) =>
  page.waitForFunction(() => ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""), null, {
    timeout: 120_000,
  });
try {
  for (const variant of ["was-400", "standard", "brisk-200", "brisk-160"]) {
    const page = await browser.newPage({ viewport: { width: 760, height: 200 }, deviceScaleFactor: 2 });
    await page.goto(base + galleryFrame("ui.motion-hover-dwell", { variant, width: 760, height: 200 }));
    await ready(page);
    await page.waitForSelector("[data-dwell-done]", { timeout: 30_000 });
    const peaks = await page.$$eval(".dwell-demo__peak", (els) => els.map((el) => el.textContent));
    console.log(variant, peaks.join(" | "));
    await page.screenshot({ path: `${out}/dwell-${variant}.png` });
    await page.close();
  }
  for (const [label, ms] of [
    ["before-400", "400ms"],
    ["after-240", "240ms"],
  ] as const) {
    const page = await browser.newPage({ viewport: { width: 760, height: 420 }, deviceScaleFactor: 2 });
    await page.goto(base + galleryFrame("agent-pane.queue-after-error", { variant: "own-retrying", width: 760, height: 420 }));
    await ready(page);
    await page.addStyleTag({ content: `:root{--cmux-hover-reveal-in:${ms} !important}` });
    const row = page.locator(".acpmux-queued").last();
    await row.waitFor({ timeout: 30_000 });
    await page.mouse.move(2, 2);
    const box = (await row.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const t0 = Date.now();
    const samples: string[] = [];
    for (const at of [60, 120, 200, 400]) {
      while (Date.now() - t0 < at) await new Promise((r) => setTimeout(r, 2));
      const opacity = await row.locator(".acpmux-queued-actions").evaluate((el) => getComputedStyle(el).opacity);
      samples.push(`${at}ms=${Number(opacity).toFixed(2)}`);
      if (at === 120)
        await page.screenshot({
          path: `${out}/queue-${label}-at120ms.png`,
          clip: { x: 0, y: Math.max(0, box.y - 20), width: 760, height: box.height + 40 },
        });
    }
    console.log(label, samples.join(" "));
    await page.close();
  }
} finally {
  await browser.close();
  await vite.close();
}
