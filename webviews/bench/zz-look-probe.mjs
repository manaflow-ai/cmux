import path from "node:path";
import { chromium, webkit } from "playwright";
import { preview } from "vite";
import { waitForFrame } from "../scripts/gallery/frameReady.mjs";
const root = path.resolve(import.meta.dir, "..");
const out = process.argv[2];
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
for (const [bn, bt] of [["chromium", chromium], ["webkit", webkit]]) {
  const browser = await bt.launch();
  for (const entry of ["agent-pane.activity-row-density", "agent-pane.agent-signature"]) {
    for (const run of [1, 2]) {
      const page = await (await browser.newContext({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 1 })).newPage();
      await page.goto(`${base}/frame.html?entry=${entry}&colorScheme=light&frame=component`);
      await waitForFrame(page, entry);
      const samples = [];
      for (let i = 0; i < 20; i++) {
        samples.push(await page.evaluate(() => {
          const min = document.querySelectorAll('[data-chat-motion="minimal"]').length;
          const bands = [...document.querySelectorAll(".cv-shimmer__band,.cv-row-shimmer__band")];
          const vis = bands.map((b) => getComputedStyle(b).visibility + "/" + getComputedStyle(b).animationName).join(",");
          return `${min}|${bands.length}|${vis}`;
        }));
        await page.waitForTimeout(50);
      }
      await page.screenshot({ path: `${out}/${bn}-${entry}-${run}.png` });
      const uniq = [...new Set(samples)];
      console.log(bn, entry, run, JSON.stringify(uniq));
      await page.close();
    }
  }
  await browser.close();
}
await server.httpServer.close();
process.exit(0);
