// Records each wallpaper as a short deterministic clip: frames drawn one by one at a fixed time
// step (no real-time clock, so a slow software GPU makes the same clip as a fast one), with a
// scripted pointer path through the middle of the clip, in the dark and light themes, plus a
// still per theme. Frames are PNGs; encode them with ffmpeg wherever it is installed.
//
//   PLAYWRIGHT_CORE=/path/to/playwright-core/index.js node design/live-wallpapers-gallery/record.mjs OUT_DIR [ids] [seconds] [fps]
//
// OUT_DIR/<id>/<theme>/still.png and OUT_DIR/<id>/<theme>/frames/000001.png ...
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [outDir, idsArg, secondsArg, fpsArg] = process.argv.slice(2);
const seconds = Number(secondsArg ?? 8);
const fps = Number(fpsArg ?? 24);
const ids = idsArg ? idsArg.split(",").filter(Boolean) : null;
// The card stands for a 1280 x 720 point window; rendered at the manifest's scale times 2.
const [W, H] = (process.env.RECORD_SIZE ?? "1280x720").split("x").map(Number);
fs.mkdirSync(outDir, { recursive: true });
const { chromium } = createRequire(process.env.PLAYWRIGHT_CORE ?? import.meta.url)("playwright-core");

const types = { ".html": "text/html", ".js": "text/javascript" };
const server = http.createServer((req, res) => {
  const file = path.join(here, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!file.startsWith(here) || !fs.existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/record.html`;

const env = { ...process.env };
delete env.DISPLAY;
const browser = await chromium.launch({
  env,
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist", "--ozone-platform=headless"],
});

const all = JSON.parse(await (async () => {
  const p = await browser.newPage();
  await p.goto(base);
  await p.waitForFunction(() => window.__ready);
  const list = await p.evaluate(() => JSON.stringify(window.__ids));
  await p.close();
  return list;
})());

const save = (file, dataUrl) => {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, Buffer.from(dataUrl.split(",")[1], "base64"));
};

async function recordOne(id) {
  const page = await browser.newPage();
  page.on("console", (m) => m.type() === "error" && console.error(`${id}: ${m.text()}`));
  await page.goto(base);
  await page.waitForFunction(() => window.__ready);
  for (const theme of ["dark", "light"]) {
    const dir = path.join(outDir, id, theme);
    save(path.join(dir, "still.png"), await page.evaluate(([id, theme, W, H]) => window.__still(id, theme, W, H), [id, theme, W, H]));
    await page.evaluate(([id, theme, W, H]) => window.__open(id, theme, W, H), [id, theme, W, H]);
    const n = Math.round(seconds * fps);
    const t0 = Date.now();
    for (let i = 0; i < n; i++) {
      const url = await page.evaluate(([i, fps, n]) => window.__frame(i, fps, n), [i, fps, n]);
      save(path.join(dir, "frames", `${String(i + 1).padStart(6, "0")}.png`), url);
    }
    const perFrame = (Date.now() - t0) / n;
    console.log(`${id} ${theme}: ${n} frames, ${perFrame.toFixed(1)} ms/frame (software GPU, not a cost number)`);
    await page.evaluate(() => window.__close());
  }
  await page.close();
}

const todo = all.filter((id) => !ids || ids.includes(id));
const parallel = Number(process.env.RECORD_PARALLEL ?? 4);
const queue = [...todo];
await Promise.all(Array.from({ length: parallel }, async () => {
  while (queue.length) await recordOne(queue.shift());
}));
await browser.close();
server.close();
