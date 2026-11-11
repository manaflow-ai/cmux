import path from "node:path";
import { chromium } from "playwright";
import { preview } from "vite";
const root = path.resolve(import.meta.dir);
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = `http://127.0.0.1:${server.httpServer.address().port}`;
const browser = await chromium.launch();
for (const variant of ["prompt-delivery", "prompt-pending"]) {
  const page = await (await browser.newContext({ viewport: { width: 760, height: 520 } })).newPage();
  page.on("console", (m) => m.type() === "error" && console.log("console:", m.text().slice(0, 300)));
  await page.goto(`${base}/frame.html?entry=agent-pane.transcript&variant=${variant}&colorScheme=dark&width=normal&frame=component`);
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 90000 });
  await page.waitForTimeout(1500);
  const info = await page.evaluate(() => {
    const users = [...document.querySelectorAll(".cv-user")];
    return users.map((u) => ({
      text: u.querySelector(".cv-user__bubble")?.textContent?.slice(0, 40),
      actions: u.querySelector(".cv-user__actions")?.className,
      actionsOpacity: u.querySelector(".cv-user__actions") ? getComputedStyle(u.querySelector(".cv-user__actions")).opacity : null,
      pending: u.querySelector(".cv-user__pending-state")?.outerHTML?.slice(0, 200),
      mark: u.querySelector(".cv-user__delivery")?.outerHTML?.slice(0, 200),
      read: !!u.querySelector(".cv-user__read"),
    }));
  });
  console.log(variant, JSON.stringify(info, null, 1));
}
await browser.close();
server.httpServer.close();
