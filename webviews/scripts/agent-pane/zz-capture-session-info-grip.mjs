// Temporary (removed before land): before/after crops of Session Info's section grip, from the gallery
// build, at 2x in dark, with the pointer on the Subagents and Context heads.
// Usage: bun zz-capture-session-info-grip.mjs OUT_DIR LABEL
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? "grip-captures");
const label = process.argv[3] ?? "capture";
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
await new Promise((resolve, reject) => {
  build.once("error", reject);
  build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
});
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const { port } = server.httpServer.address();
const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 900, height: 1400 }, deviceScaleFactor: 2, colorScheme: "dark" });
  await page.goto(
    `http://127.0.0.1:${port}/frame.html?entry=agent-pane.chat-inspector&variant=push&colorScheme=dark&width=normal&frame=component`,
    { waitUntil: "domcontentloaded" },
  );
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 60_000 });
  for (const id of ["subagents", "context"]) {
    const head = `section[data-section="${id}"] > .acpmux-session-info-section__disclosure > .ui-disclosure-trigger`;
    await page.locator(head).scrollIntoViewIfNeeded();
    await page.hover(head);
    await page.waitForFunction(
      (id) => getComputedStyle(document.querySelector(`section[data-section="${id}"] > .acpmux-session-info-section__handle`)).opacity === "1",
      id,
    );
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const pill = await page.locator(head).boundingBox();
    // Leo's crop: about 72 by 60 CSS px around the pill's left edge, at 2x.
    await page.screenshot({ path: path.join(out, `${label}-${id}.png`), clip: { x: pill.x - 28, y: pill.y - 14, width: 72, height: 60 } });
    await page.screenshot({ path: path.join(out, `${label}-${id}-wide.png`), clip: { x: pill.x - 28, y: pill.y - 14, width: 240, height: 60 } });
    const m = await page.evaluate((head) => {
      const t = document.querySelector(head);
      const p = t.getBoundingClientRect();
      const d = t.closest("section").querySelector(":scope > .acpmux-session-info-section__handle svg").getBoundingClientRect();
      return { dotsFromPillLeft: [d.left - p.left, d.right - p.left], dotsMidMinusPillMid: d.top + d.height / 2 - (p.top + p.height / 2) };
    }, head);
    console.log(`${label} ${id} ${JSON.stringify(m)}`);
  }
} finally {
  await browser.close();
  server.httpServer.close();
}
