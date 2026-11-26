// Records the app scene motion gallery entry (apps.scene-effects: loops, springs, transitions,
// shapes, particles) as one video, in Chromium, about 3 s per variant.
// Usage: bun capture-scene-motion.mjs OUT_DIR [SECONDS_PER_VARIANT]
// Writes scene-motion.webm (and one PNG per variant) to OUT_DIR. On a fleet host:
//   cmux-ci test --setup playwright --artifact DIR -- 'cd webviews && bun scripts/apps/capture-scene-motion.mjs "$FAST_CHECKS_OUT"'
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const out = path.resolve(process.argv[2] ?? process.env.FAST_CHECKS_OUT ?? "scene-motion-captures");
const seconds = Number(process.argv[3] ?? 3);
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
const variants = ["loops", "springs", "transitions", "shapes", "particles"];
const size = { width: 560, height: 380 };
try {
  const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
  try {
    const context = await browser.newContext({
      viewport: size,
      deviceScaleFactor: 1,
      colorScheme: "dark",
      recordVideo: { dir: out, size },
    });
    const page = await context.newPage();
    for (const variant of variants) {
      const url = `${baseUrl}/frame.html?entry=apps.scene-effects&variant=${variant}&colorScheme=dark&width=normal&frame=component`;
      await page.goto(url, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      await page.waitForSelector(".cmux-app-scene-root", { timeout: 60_000 });
      // fixed-wait: the recording is the behavior; each variant plays for a fixed length of video
      await page.waitForTimeout(seconds * 1000);
      await page.screenshot({ path: path.join(out, `scene-motion-${variant}.png`) });
      console.log(`recorded ${variant}`);
    }
    const video = page.video();
    await context.close();
    if (video) {
      const target = path.join(out, "scene-motion.webm");
      await video.saveAs(target);
      console.log(`wrote ${target}`);
    }
  } finally {
    await browser.close();
  }
} finally {
  await server.close();
}
