// Records a short clip of the glass engine over a colorful wallpaper: plain glass first, then the engine
// (data-glass-engine, the host's ask for Debug > Liquid Glass > Glass Engine) with the pointer moving.
// Run: bun scripts/glass-engine-clip.ts OUT_DIR   (needs playwright and a Chromium with WebGL)
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";

const out = process.argv[2] ?? "glass-engine-clip";
fs.mkdirSync(out, { recursive: true });
const source = path.resolve(import.meta.dir, "../src");
const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
  .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
  .join("\n");
const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glass-clip-")), "entry.ts");
fs.writeFileSync(
  entry,
  `import { installGlassLens } from ${JSON.stringify(path.join(source, "ui/glass/lens.ts"))};
   Object.assign(window, { installGlassLens });`,
);
const built = await Bun.build({ entrypoints: [entry], target: "browser" });
if (!built.success) throw new Error(built.logs.join("\n"));
const script = await built.outputs[0]!.text();

const html = `<!doctype html><html data-glass="lens" style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,30,30)">
<head><style>${css}
 body{margin:0;font:600 20px system-ui;color:#fff}
 .box{position:absolute;left:160px;top:110px;width:480px;height:240px;border-radius:40px;display:grid;place-items:center;
   --glass-refraction:36px}
 .label{position:absolute;left:16px;top:12px;text-shadow:0 1px 3px #000}
</style></head><body><div class="label" id="label">Plain glass (blur only)</div>
<div class="box ui-glass"><span>Glass engine</span></div></body></html>`;

const browser = await chromium.launch({
  headless: true,
  args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"],
});
const context = await browser.newContext({
  viewport: { width: 800, height: 460 },
  deviceScaleFactor: 1,
  recordVideo: { dir: out, size: { width: 800, height: 460 } },
});
const page = await context.newPage();
await page.setContent(html);
await page.addScriptTag({ content: script });
await page.evaluate(async () => {
  const canvas = document.createElement("canvas");
  canvas.width = innerWidth;
  canvas.height = innerHeight;
  const c = canvas.getContext("2d")!;
  const g = c.createLinearGradient(0, 0, canvas.width, canvas.height);
  g.addColorStop(0, "#ff7a18");
  g.addColorStop(0.5, "#2b6cff");
  g.addColorStop(1, "#14c8a0");
  c.fillStyle = g;
  c.fillRect(0, 0, canvas.width, canvas.height);
  c.fillStyle = "rgba(255,255,255,.9)";
  for (let x = 0; x < canvas.width; x += 40) c.fillRect(x, 0, 6, canvas.height);
  for (let y = 0; y < canvas.height; y += 40) c.fillRect(0, y, canvas.width, 6);
  const image = canvas.toDataURL("image/png");
  document.documentElement.style.setProperty(
    "background",
    `url(${image}) 0 0 / 100vw 100vh no-repeat fixed`,
    "important",
  );
  const host = window as unknown as { installGlassLens(d: Document): void; cmuxTheme: { backdrop(p: unknown): void } };
  host.installGlassLens(document);
  host.cmuxTheme.backdrop({
    image,
    key: "clip",
    rect: { x: 0, y: 0, width: innerWidth, height: innerHeight },
    blur: 0,
    tint: "transparent",
  });
  for (let i = 0; i < 30; i++) await new Promise(requestAnimationFrame);
});
// Plain first: the lens attribute off.
await page.evaluate(() => document.documentElement.setAttribute("data-glass", "plain"));
await page.waitForTimeout(1500);
await page.evaluate(() => {
  document.documentElement.setAttribute("data-glass", "lens");
  document.documentElement.setAttribute("data-glass-engine", "");
  document.getElementById("label")!.textContent =
    "Glass engine ON: refraction, lit rim, adaptive tint (pointer moves the light)";
});
for (let i = 0; i <= 90; i++) {
  const t = i / 90;
  await page.mouse.move(120 + 560 * t, 90 + 280 * Math.abs(Math.sin(t * Math.PI * 2)));
  await page.waitForTimeout(40);
}
await page.screenshot({ path: path.join(out, "engine.png") });
const state = await page.evaluate(() => document.documentElement.hasAttribute("data-glass-engine-draws"));
console.log("engine drawing:", state);
await context.close();
await browser.close();
for (const f of fs.readdirSync(out)) console.log("wrote", f);
