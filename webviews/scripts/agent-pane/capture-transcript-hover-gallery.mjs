// Capture the real transcript gallery entry with a coarse pointer.
// Usage: bun capture-transcript-hover-gallery.mjs OUT_DIR [dark|light]
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";

const out = path.resolve(process.argv[2] ?? "transcript-hover-gallery-captures");
const scheme = process.argv[3] === "light" ? "light" : "dark";
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
const port = 4179;
const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
await new Promise((resolve, reject) => {
  build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
});
const server = spawn("bun", ["x", "vite", "preview", "--config", "vite.config.gallery.ts", "--host", "127.0.0.1", "--port", String(port)], { cwd: root, stdio: "ignore" });
const stop = () => server.kill("SIGTERM");
process.on("exit", stop);
try {
  await new Promise((resolve) => setTimeout(resolve, 1000));
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ viewport: { width: 1000, height: 720 }, deviceScaleFactor: 2, hasTouch: true, colorScheme: scheme });
    const page = await context.newPage();
    const url = `http://127.0.0.1:${port}/frame.html?entry=agent-pane.transcript&variant=footer-actions-left&colorScheme=${scheme}&width=normal&frame=component`;
    await page.goto(url, { waitUntil: "domcontentloaded" });
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 60_000 });
    await page.evaluate(() => {
      for (const selector of [".cv-user", ".cv-received", ".acpmux-turnSummary", ".acpmux-assistant"]) {
        for (const element of document.querySelectorAll(selector)) element.classList.add("capture-hover");
      }
      const style = document.createElement("style");
      style.textContent = ".capture-hover .cv-user__actions,.capture-hover .cv-received-actions,.capture-hover .cv-reply-actions,.capture-hover .cv-turn-actions{opacity:1!important;transition:none!important}";
      document.head.append(style);
    });
    const target = page.locator(".acpmux-shell").first();
    const box = await target.boundingBox();
    if (!box) throw new Error("transcript gallery shell did not render");
    const file = path.join(out, `after-${scheme}-coarse.png`);
    await page.screenshot({ path: file, clip: { x: Math.max(0, box.x - 32), y: Math.max(0, box.y - 32), width: box.width + 64, height: box.height + 64 } });
    const metrics = await page.evaluate(() => {
      const group = document.querySelector(".cv-turn-action-group");
      const copy = group?.querySelector('button[aria-label="Copy"]');
      const retry = group?.querySelector('button[aria-label="Retry"]');
      return { shell: document.querySelector(".acpmux-shell")?.getBoundingClientRect().toJSON(), copyRetryGap: copy && retry ? retry.getBoundingClientRect().left - copy.getBoundingClientRect().right : null, dpr: devicePixelRatio };
    });
    console.log(JSON.stringify({ scheme, file, metrics, base: process.env.CMUX_CAPTURE_BASE_SHA ?? null }));
    console.log(`CAPTURE_BASE64 ${path.basename(file)} ${fs.readFileSync(file).toString("base64")}`);
    await context.close();
  } finally {
    await browser.close();
  }
} finally {
  stop();
}
