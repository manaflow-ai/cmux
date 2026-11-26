// Captures the gallery as stills: one PNG per wallpaper section (?still=1), plus a short
// pointer sweep per wallpaper as frames, so a change can be looked at without a Mac.
//
//   PLAYWRIGHT_CORE=/path/to/playwright-core/index.js node design/live-wallpapers-gallery/shoot.mjs OUT_DIR [id]
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const [outDir, only] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const { chromium } = createRequire(process.env.PLAYWRIGHT_CORE ?? import.meta.url)("playwright-core");

// Module scripts do not load from file://, so serve this folder.
const types = { ".html": "text/html", ".js": "text/javascript" };
const server = http.createServer((req, res) => {
  const file = path.join(here, decodeURIComponent(new URL(req.url, "http://x").pathname));
  if (!file.startsWith(here) || !fs.existsSync(file)) return res.writeHead(404).end();
  res.writeHead(200, { "content-type": types[path.extname(file)] ?? "application/octet-stream" });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const base = `http://127.0.0.1:${server.address().port}/index.html`;

// No X display: on a host with DISPLAY set but no server behind it, the GPU process crashes on
// xcb_connect and WebGL2 is off, so every card is black.
const env = { ...process.env };
delete env.DISPLAY;
const browser = await chromium.launch({
  env,
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist", "--ozone-platform=headless"],
});
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
// SwiftShader draws every card on the CPU: a heavy program on a busy host takes a while.
page.setDefaultTimeout(Number(process.env.SHOOT_TIMEOUT_MS ?? 600000));
page.on("console", (m) => m.type() === "error" && console.error(m.text()));

await page.goto(`${base}?still=1${only ? `&id=${only}` : ""}`);
await page.waitForSelector("body[data-ready]");
for (const section of await page.$$("section")) {
  const id = await section.getAttribute("id");
  await section.screenshot({ path: path.join(outDir, `${id}-stills.png`) });
  console.log(`${id}-stills.png`);
}

// A motion scene: each card's still at full size, then a frame sequence across one loop (8 frames
// of the first card), all from Rust's packed uniforms (build.mjs).
const png = (url) => Buffer.from(url.slice(url.indexOf(",") + 1), "base64");
const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-");
for (const section of await page.$$("section[data-scene]")) {
  const id = await section.getAttribute("id");
  const cards = await section.$$eval("figure[data-card]", (fs) => fs.map((f) => f.dataset.card));
  for (const card of cards) {
    const { url } = await page.evaluate(([i, c]) => window.sceneFrame(i, c, "still"), [id, card]);
    const name = `${id}-${card.split("|").map(slug).join("-")}.png`;
    fs.writeFileSync(path.join(outDir, name), png(url));
    console.log(name);
  }
  // SHOOT_FRAMES: how many frames of the card's sequence, spread evenly (default 8), or "all".
  const seqCard = await page.evaluate((i) => window.sceneSequenceCard(i), id);
  if (!seqCard) continue;
  const { count } = await page.evaluate(([i, c]) => window.sceneFrame(i, c, 0), [id, seqCard]);
  const want = process.env.SHOOT_FRAMES === "all" ? count : Math.min(count, Number(process.env.SHOOT_FRAMES ?? 8));
  for (let k = 0; k < want; k++) {
    const frame = Math.floor((k * count) / want);
    const { url } = await page.evaluate(([i, c, f]) => window.sceneFrame(i, c, f), [id, seqCard, frame]);
    fs.writeFileSync(path.join(outDir, `${id}-frame-${String(k).padStart(3, "0")}.png`), png(url));
  }
  console.log(`${id}-frame-*.png`);
}

// A pointer sweep on the first card of each wallpaper, live: 4 frames across the card
// (SHOOT_SWEEP=0 skips it).
if (process.env.SHOOT_SWEEP === "0") {
  await browser.close();
  server.close();
  process.exit(0);
}
await page.goto(`${base}${only ? `?id=${only}` : ""}`);
await page.waitForSelector("body[data-ready]");
for (const section of await page.$$("section")) {
  const id = await section.getAttribute("id");
  // A card runs live only once it is on screen: bring the first one in, then take its canvas.
  await (await section.$("figure")).scrollIntoViewIfNeeded();
  const canvas = await section.waitForSelector("canvas");
  const box = await canvas.boundingBox();
  for (let i = 0; i < 4; i++) {
    const fx = 0.2 + i * 0.2;
    await page.mouse.move(box.x + box.width * fx, box.y + box.height * (0.35 + 0.1 * i), { steps: 8 });
    // Short enough to catch a wake or ripple before it settles.
    await page.waitForTimeout(120);
    await canvas.screenshot({ path: path.join(outDir, `${id}-sweep-${i}.png`) });
  }
  console.log(`${id}-sweep-*.png`);
}
await browser.close();
server.close();
