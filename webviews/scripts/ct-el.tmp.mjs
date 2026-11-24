import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";
const root = process.cwd();
const [, , entry, variant, sel, out] = process.argv;
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
const browser = await chromium.launch({ channel: "chrome" });
const page = await (
  await browser.newContext({ viewport: { width: 1100, height: 760 }, colorScheme: "dark", deviceScaleFactor: 2 })
).newPage();
const q = new URLSearchParams({ entry, variant, colorScheme: "dark", width: "narrow", frame: "component" });
await page.goto(`${base}/frame.html?${q}`);
await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
await page.evaluate(() => document.fonts.ready);
await page.waitForTimeout(400);
const el = page.locator(sel).first();
await el.scrollIntoViewIfNeeded();
if (sel === "body") await page.screenshot({ path: out, fullPage: true });
else await el.screenshot({ path: out });
console.log(await el.evaluate((e) => e.getBoundingClientRect().width));
await browser.close();
server.httpServer.close();
process.exit(0);
