// Record gallery states as video, headless: each shot loads one entry/variant in the stage frame and records it for a
// fixed time (an animating variant: a resize, a motion), as capture-states.mjs takes stills.
//
// Usage: bun scripts/gallery/record-states.mjs SPEC.json OUT_DIR
//   SPEC.json: { "shots": [{ "name": "tab-overflow-chevrons", "entry": "agent-pane.tab-overflow",
//                            "variant": "chevrons-resize", "scheme": "light", "width": 1240, "height": 480,
//                            "widthName": "wide", "seconds": 8, "hover": ".css-selector (optional)" }] }
// Writes OUT_DIR/<shot>.webm and prints one JSON line per recording.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const spec = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
const out = path.resolve(process.argv[3] ?? process.env.FAST_CHECKS_OUT ?? "gallery-state-recordings");
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

let failures = 0;
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  for (const shot of spec.shots) {
    const size = { width: shot.width ?? 1240, height: shot.height ?? 480 };
    const scratch = fs.mkdtempSync(path.join(out, ".rec-"));
    const context = await browser.newContext({
      viewport: size,
      colorScheme: shot.scheme ?? "light",
      recordVideo: { dir: scratch, size },
    });
    const page = await context.newPage();
    const query = new URLSearchParams({
      entry: shot.entry,
      colorScheme: shot.scheme ?? "light",
      width: shot.widthName ?? "normal",
      frame: shot.frame ?? "component",
    });
    if (shot.variant) query.set("variant", shot.variant);
    if (shot.opts) query.set("opts", shot.opts);
    try {
      await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 90_000,
      });
      if (shot.hover) await page.locator(shot.hover).first().hover({ timeout: 10_000 });
      await page.waitForTimeout((shot.seconds ?? 8) * 1000);
      const video = page.video();
      await context.close();
      const file = path.join(out, `${shot.name}.webm`);
      fs.renameSync(await video.path(), file);
      console.log(JSON.stringify({ shot: shot.name, file: path.relative(out, file) }));
    } catch (error) {
      failures += 1;
      await context.close().catch(() => {});
      console.log(JSON.stringify({ shot: shot.name, error: String(error).slice(0, 300) }));
    }
    fs.rmSync(scratch, { recursive: true, force: true });
  }
} finally {
  await browser.close();
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
if (failures) {
  console.error(`${failures} recording(s) failed`);
  process.exitCode = 1;
}
