import path from "node:path";
import { chromium } from "playwright";
import { createServer } from "vite";
import { galleryFrame } from "./test/support/galleryFrame";
const vite = await createServer({
  configFile: path.resolve("vite.config.gallery-dev.ts"),
  server: { port: 0, host: "127.0.0.1" },
  logLevel: "error",
});
await vite.listen();
const port = (vite.httpServer!.address() as { port: number }).port;
const browser = await chromium.launch({ headless: true, executablePath: "/usr/bin/google-chrome" });
const page = await browser.newPage({
  viewport: { width: 420, height: 240 },
  reducedMotion: "reduce",
  deviceScaleFactor: 2,
});
await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.since-divider", { variant: "line-worked" })}`, {
  timeout: 300_000,
});
await page.locator(".cv-worked").first().waitFor({ timeout: 300_000 });
await page.waitForTimeout(500);
const probe = () =>
  page.evaluate(() => {
    const t = document.querySelector(".cv-since__tag")!;
    const r = t.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    const m = document.querySelector(".cv-since__menu")!;
    const ms = getComputedStyle(m);
    const row = m.closest(".acpmux-row")!;
    const rs = getComputedStyle(row);
    return {
      tag: [r.x, r.y, r.width, r.height],
      hit: hit?.className?.toString(),
      menu: [m.getBoundingClientRect().y, m.getBoundingClientRect().height, ms.contain, ms.overflow],
      row: [row.getBoundingClientRect().y, row.getBoundingClientRect().height, rs.contain, rs.overflow, rs.clipPath],
    };
  });
console.log("WITH", JSON.stringify(await probe()));
await page.screenshot({ path: "/tmp/cap/dbg-with.png" });
await page.addStyleTag({ content: ".cv-since__menu{container:none !important}" });
await page.waitForTimeout(300);
console.log("WITHOUT", JSON.stringify(await probe()));
await page.screenshot({ path: "/tmp/cap/dbg-without.png" });
await browser.close();
await vite.close();
