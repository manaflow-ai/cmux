// Capture the jump pair's looks (gallery agent-pane.jump-pair-look, jumpPair.experiment.ts) in
// Chromium, light and dark: each variant's whole pane, and a crop round the pair over the composer.
// Usage: bun scripts/agent-pane/capture-jump-pair-look.mjs OUT_DIR [VARIANT,...]
// Builds the gallery first when dist/gallery is missing (or CMUX_CAPTURE_BUILD=1).
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const ENTRY = "agent-pane.jump-pair-look";
const out = path.resolve(process.argv[2] ?? "jump-pair-look-captures");
const variants = process.argv[3]?.split(",").filter(Boolean) ?? [
  "frosted",
  "labeled",
  "stacked",
  "lens",
  "frosted-image",
];
fs.mkdirSync(out, { recursive: true });
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
let failed = 0;
try {
  const browser = await chromium.launch();
  try {
    for (const scheme of ["dark", "light"]) {
      const context = await browser.newContext({
        viewport: { width: 900, height: 640 },
        deviceScaleFactor: 2,
        colorScheme: scheme,
      });
      for (const variant of variants) {
        const page = await context.newPage();
        const url = `${baseUrl}/frame.html?entry=${ENTRY}&variant=${variant}&colorScheme=${scheme}&width=normal&frame=component`;
        try {
          await page.goto(url, { waitUntil: "domcontentloaded" });
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          await page.waitForSelector(".acpmux-jump-up[data-shown]", { timeout: 30_000 });
          await page.waitForTimeout(600);
          await page.screenshot({ path: path.join(out, `${variant}-${scheme}.png`) });
          const latest = await page.locator(".acpmux-jump-latest:not(.acpmux-jump-up)").boundingBox();
          const up = await page.locator(".acpmux-jump-up").boundingBox();
          if (latest && up) {
            const cx = latest.x + latest.width / 2;
            const top = Math.min(latest.y, up.y) - 40;
            const bottom = Math.max(latest.y + latest.height, up.y + up.height) + 40;
            await page.screenshot({
              path: path.join(out, `${variant}-${scheme}-crop.png`),
              clip: { x: Math.max(0, cx - 120), y: Math.max(0, top), width: 240, height: bottom - top },
            });
          }
          const info = await page.evaluate(() => {
            const b = document.querySelector(".acpmux-jump-latest:not(.acpmux-jump-up)");
            const u = document.querySelector(".acpmux-jump-up");
            const s = b && getComputedStyle(b);
            return {
              look: b?.getAttribute("data-look"),
              upLook: u?.getAttribute("data-look"),
              fisheye: b?.classList.contains("ui-glass-fisheye"),
              backdrop: s?.backdropFilter,
              fill: s?.backgroundColor,
              radius: s?.borderRadius,
              latest: b?.getBoundingClientRect().toJSON(),
              up: u?.getBoundingClientRect().toJSON(),
            };
          });
          console.log(`SHOT ${variant}-${scheme} ${JSON.stringify(info)}`);
        } catch (error) {
          failed++;
          console.log(`FAIL ${variant}-${scheme} ${String(error)}`);
          await page.screenshot({ path: path.join(out, `${variant}-${scheme}-FAILED.png`) }).catch(() => {});
        }
        await page.close();
      }
      await context.close();
    }
  } finally {
    await browser.close();
  }
} finally {
  await new Promise((resolve) => server.httpServer.close(resolve));
}
if (failed) process.exit(1);
