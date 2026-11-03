// Capture the header tools' glass from the real gallery entry (agent-pane.header, glass-* variants), in Chromium at
// 2x, cropped round the tools with the rows beside them, light and dark.
// Usage: bun capture-header-glass.mjs OUT_DIR [VARIANT,...]
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? "header-glass-captures");
fs.mkdirSync(out, { recursive: true });
const variants = (
  process.argv[3] ??
  "glass-pill-rest,glass-pill-over-text,glass-none-over-text,glass-faint-rest,glass-circles-over-text"
)
  .split(",")
  .filter(Boolean);
const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery")) || process.env.CMUX_CAPTURE_BUILD === "1") {
  const build = spawn("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  await new Promise((resolve, reject) => {
    build.once("error", reject);
    build.once("exit", (code) => (code === 0 ? resolve() : reject(new Error(`gallery build exited ${code}`))));
  });
}
const server = await preview({
  root,
  configFile: path.join(root, "vite.config.gallery.ts"),
  preview: { host: "127.0.0.1", port: 0 },
});
const address = server.httpServer.address();
if (!address || typeof address === "string") throw new Error("gallery preview did not bind a TCP port");
const baseUrl = `http://127.0.0.1:${address.port}`;
try {
  const browser = await chromium.launch();
  try {
    for (const scheme of ["light", "dark"]) {
      const context = await browser.newContext({
        viewport: { width: 900, height: 720 },
        deviceScaleFactor: 2,
        colorScheme: scheme,
      });
      for (const variant of variants) {
        const page = await context.newPage();
        const url = `${baseUrl}/frame.html?entry=agent-pane.header&variant=${variant}&colorScheme=${scheme}&width=normal&frame=component`;
        await page.goto(url, { waitUntil: "domcontentloaded" });
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 90_000,
        });
        await page.evaluate(
          () => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(done, 400)))),
        );
        const box = await page.locator(".acpmux-header[data-tab-row] .acpmux-header-tools").boundingBox();
        if (!box) throw new Error(`${variant}: the header tools did not render`);
        const info = await page.evaluate(() => {
          const tools = document.querySelector(".acpmux-header[data-tab-row] .acpmux-header-tools");
          const glass = tools && getComputedStyle(tools, "::before");
          return { opacity: glass?.opacity, backdrop: glass?.backdropFilter, background: glass?.backgroundColor };
        });
        const x = Math.max(0, box.x + box.width - 300);
        const file = path.join(out, `${variant}-${scheme}.png`);
        await page.screenshot({ path: file, clip: { x, y: Math.max(0, box.y - 10), width: 300 + 12, height: 64 } });
        console.log(`CAPTURE ${scheme} ${variant} ${JSON.stringify(info)}`);
        await page.close();
      }
      await context.close();
    }
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
