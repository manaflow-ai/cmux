// Records any gallery entry in Chromium: one video and one PNG per variant, plus one combined video
// of all variants. Reusable for every example extension that has a scene gallery entry.
// Usage: bun capture-scene-entry.mjs OUT_DIR ENTRY VARIANTS [SECONDS=12] [SHOT_AT=4] [WIDTHxHEIGHT=1060x880] [ROOTS=2]
//   VARIANTS is comma-separated; ROOTS is how many .cmux-app-scene-root elements mean "drawn".
// On a fleet host:
//   cmux-ci test --setup playwright --artifact DIR -- 'cd webviews && bun scripts/apps/capture-scene-entry.mjs "$FAST_CHECKS_OUT" apps.leo-gacha holo,pixel,glass'
import fs from "node:fs";
import path from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const [outArg, entry, variantArg, secondsArg, shotArg, sizeArg, rootsArg] = process.argv.slice(2);
if (!outArg || !entry || !variantArg)
  throw new Error("usage: capture-scene-entry.mjs OUT_DIR ENTRY VARIANTS [SECONDS] [SHOT_AT] [WxH] [ROOTS]");
const out = path.resolve(outArg);
const variants = variantArg.split(",").filter(Boolean);
const seconds = Number(secondsArg ?? 12);
const shotAt = Number(shotArg ?? 4);
const [width, height] = (sizeArg ?? "1060x880").split("x").map(Number);
const roots = Number(rootsArg ?? 2);
const name = entry.replace(/^apps\./, "");
fs.mkdirSync(out, { recursive: true });
const root = path.resolve(import.meta.dir, "../..");
if (!fs.existsSync(path.join(root, "dist/gallery")) || process.env.CMUX_CAPTURE_BUILD !== "0") {
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
const size = { width, height };
const url = (variant) =>
  `${baseUrl}/frame.html?entry=${entry}&variant=${variant}&colorScheme=dark&width=normal&frame=component`;

async function open(page, variant) {
  await page.goto(url(variant), { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
    timeout: 90_000,
  });
  await page.waitForFunction((n) => document.querySelectorAll(".cmux-app-scene-root").length >= n, roots, {
    timeout: 60_000,
  });
  // CAPTURE_PROBE=selector prints each match's box, its parent's and its first child's, to check layout.
  const probe = process.env.CAPTURE_PROBE;
  if (probe) {
    const boxes = await page.evaluate((sel) => {
      const box = (e) => {
        if (!e) return null;
        const r = e.getBoundingClientRect();
        const cs = getComputedStyle(e);
        return {
          cls: String(e.className),
          w: r.width,
          h: r.height,
          y: r.y,
          display: cs.display,
          height: cs.height,
          alignSelf: cs.alignSelf,
        };
      };
      return [...document.querySelectorAll(sel)].map((el) => ({
        el: box(el),
        parent: box(el.parentElement),
        child: box(el.firstElementChild),
      }));
    }, probe);
    console.log(`probe ${variant}: ${JSON.stringify(boxes)}`);
  }
}

function toMp4(webm) {
  const mp4 = webm.replace(/\.webm$/, ".mp4");
  const r = spawnSync("ffmpeg", [
    "-y",
    "-loglevel",
    "error",
    "-i",
    webm,
    "-c:v",
    "libx264",
    "-pix_fmt",
    "yuv420p",
    "-movflags",
    "+faststart",
    mp4,
  ]);
  if (r.status === 0) console.log(`wrote ${mp4}`);
  else console.log(`no mp4 for ${webm}: ${r.error?.message ?? r.stderr?.toString().trim()}`);
}

async function record(browser, file, body) {
  const context = await browser.newContext({
    viewport: size,
    deviceScaleFactor: 1,
    colorScheme: "dark",
    recordVideo: { dir: out, size },
  });
  const page = await context.newPage();
  page.on("console", (m) => m.type() === "error" && console.log(`[${file}] console error: ${m.text()}`));
  page.on("pageerror", (e) => console.log(`[${file}] page error: ${e.message}`));
  await body(page);
  const video = page.video();
  await context.close();
  if (video) {
    const target = path.join(out, `${file}.webm`);
    await video.saveAs(target);
    await video.delete();
    console.log(`wrote ${target}`);
    toMp4(target);
  }
}

try {
  const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
  try {
    for (const variant of variants) {
      await record(browser, `${name}-${variant}`, async (page) => {
        await open(page, variant);
        // fixed-wait: the recording is the behavior; each variant plays for a fixed length of video
        await page.waitForTimeout(shotAt * 1000);
        await page.screenshot({ path: path.join(out, `${name}-${variant}.png`) });
        await page.waitForTimeout(Math.max(0, seconds - shotAt) * 1000);
        await page.screenshot({ path: path.join(out, `${name}-${variant}-end.png`) });
        console.log(`recorded ${variant}`);
      });
    }
    if (variants.length > 1)
      await record(browser, `${name}-all`, async (page) => {
        for (const variant of variants) {
          await open(page, variant);
          // fixed-wait: each variant plays for a fixed length of the combined video
          await page.waitForTimeout(4500);
        }
      });
  } finally {
    await browser.close();
  }
} finally {
  await server.close();
}
