import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";
const root = process.cwd();
const list = JSON.parse(process.argv[2]); // [[entry,variant,sample],...]
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
for (const [entry, variant, sample] of list) {
  const q = new URLSearchParams({ entry, colorScheme: "dark", width: "narrow", frame: "component" });
  if (variant) q.set("variant", variant);
  await page.goto(`${base}/frame.html?${q}`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
    timeout: 20000,
  });
  await page.evaluate(() => document.fonts.ready.then(() => new Promise((r) => setTimeout(r, 400))));
  const box = await page.evaluate((s) => {
    const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n; (n = w.nextNode());)
      if (
        n.textContent.includes(s.slice(0, 20)) &&
        (!s.startsWith("density") || n.parentElement.closest(".density-preview"))
      ) {
        const r = n.parentElement.getBoundingClientRect();
        n.parentElement.style.outline = "2px solid red";
        return { x: r.x, y: r.y };
      }
  }, sample);
  const y = Math.max(0, (box?.y ?? 0) - 160);
  await page
    .screenshot({ path: `/tmp/ctscan/shots/${entry}--${variant}.png`, clip: { x: 0, y, width: 1100, height: 320 } })
    .catch(async () => page.screenshot({ path: `/tmp/ctscan/shots/${entry}--${variant}.png` }));
}
await browser.close();
server.httpServer.close();
process.exit(0);
