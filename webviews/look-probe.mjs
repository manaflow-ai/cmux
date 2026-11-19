// Capture only (looks-threads-console helper, not for a PR): open one gallery frame and print what it
// says (console, page errors, the ready flag, the body text) so a frame that never reports ready
// can be read from the log.
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const root = path.resolve(import.meta.dir);
const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: ["ignore", "ignore", "inherit"] });
await new Promise((resolve, reject) => {
  build.once("error", reject);
  build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
});
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const baseUrl = `http://127.0.0.1:${server.httpServer.address().port}`;
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
for (const [entry, variant] of [
  ["agent-pane.new-tab-looks", "threads-few"],
  ["agent-pane.new-tab", "look-threads-few"],
]) {
  const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
  page.on("console", (m) => console.log(`PROBE ${variant} console.${m.type()}: ${m.text().slice(0, 400)}`));
  page.on("pageerror", (e) => console.log(`PROBE ${variant} pageerror: ${String(e.stack ?? e).slice(0, 800)}`));
  const query = new URLSearchParams({ entry, variant, colorScheme: "light", width: "normal", frame: "component" });
  await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
  await page
    .waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 30_000 })
    .catch(() => {});
  await page.waitForTimeout(3000);
  const state = await page.evaluate(() => ({
    ready: document.documentElement.dataset.galleryReady ?? null,
    body: document.body.innerText.slice(0, 600),
    app: document.querySelector(".nt-app-page")?.getAttribute("data-status") ?? null,
  }));
  console.log(`PROBE ${variant} state: ${JSON.stringify(state)}`);
  await page.close();
}
await browser.close();
await server.close();
