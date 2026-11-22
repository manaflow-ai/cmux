// Scratch capture for the PR (not committed): every status of agent-pane.live-spot-shimmer in light,
// dark and glass, plus a short clip of the shimmer running.
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";
const root = path.resolve(import.meta.dir, "..");
const out = path.resolve(process.argv[2]);
fs.mkdirSync(out, { recursive: true });
if (!fs.existsSync(path.join(root, "dist/gallery"))) {
  const r = spawnSync("bun", ["run", "gallery:build"], { cwd: root, stdio: "inherit" });
  if (r.status !== 0) process.exit(r.status ?? 1);
}
const server = await preview({ root, configFile: path.join(root, "vite.config.gallery.ts"), preview: { host: "127.0.0.1", port: 0 } });
const base = server.resolvedUrls.local[0].replace(/\/$/, "");
const browser = await chromium.launch();
const url = (scheme, variant, extra = {}) =>
  `${base}/frame.html?${new URLSearchParams({ entry: "agent-pane.live-spot-shimmer", variant, colorScheme: scheme, width: "normal", frame: "component", ...extra })}`;
const ready = (page) => page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 90_000 });
for (const scheme of ["light", "dark"])
  for (const variant of ["plain", "glass"]) {
    const ctx = await browser.newContext({ viewport: { width: 720, height: 760 }, deviceScaleFactor: 2, colorScheme: scheme });
    const page = await ctx.newPage();
    await page.goto(url(scheme, variant, variant === "glass" ? { background: "busy" } : {}));
    await ready(page);
    await page.waitForTimeout(1500);
    await page.screenshot({ path: path.join(out, `live-spot-${scheme}-${variant}.png`) });
    await ctx.close();
    console.log("shot", scheme, variant);
  }
// The clip: dark, the continuous pass so every row is seen moving within the clip.
const ctx = await browser.newContext({ viewport: { width: 720, height: 760 }, colorScheme: "dark", recordVideo: { dir: out, size: { width: 720, height: 760 } } });
const page = await ctx.newPage();
await page.goto(url("dark", "plain"));
await ready(page);
await page.evaluate(() => {
  const r = document.documentElement;
  r.dataset.thinkingShimmer = "continuous";
  r.style.setProperty("--cv-shimmer-period", "1250ms");
});
await page.waitForTimeout(8000);
const video = await page.video().path();
await ctx.close();
fs.renameSync(video, path.join(out, "live-spot-dark.webm"));
spawnSync("ffmpeg", ["-y", "-loglevel", "error", "-i", path.join(out, "live-spot-dark.webm"), "-ss", "1", "-t", "7", "-pix_fmt", "yuv420p", "-movflags", "+faststart", path.join(out, "live-spot-dark.mp4")], { stdio: "inherit" });
await browser.close();
await server.close();
console.log(fs.readdirSync(out).join("\n"));
