// Capture gallery states headless, in light and dark, on an opaque window and over a picture, and lay
// each state's design arms out as one sheet: a row per arm, a column per appearance.
// An arm is the state with extra CSS injected (a candidate design), so one build shows the current
// look and every candidate side by side, without a branch per candidate.
//
// Usage: bun scripts/gallery/capture-states.mjs SPEC.json OUT_DIR
//   SPEC.json: { "envs": [["light","none"],["dark","none"],["dark","busy"],["light","busy"]],
//                "shots": [{ "name": "slash-menu", "entry": "agent-pane.slash-menu", "variant": "…",
//                            "opts": "k:v;…", "width": 760, "height": 420, "deviceScaleFactor": 2,
//                            "clip": ".css-selector (optional: crop to it, plus a margin)",
//                            "setup": "JS run in the page before the shot (optional)",
//                            "hover": ".css-selector the pointer rests on (optional)",
//                            "arms": { "now": "", "A": "css…", "B": "css…" },
//                            "armQuery": { "A": { "exp": "turn-fold-replies", "arm": "groups" } } }] }
// An arm's `armQuery` (optional) adds frame.html query parameters for that arm alone, so one build
// shows an experiment's arms side by side (exp + arm pick the arm, gallery/frame/main.ts): a Before
// row on the old arm and an After row on the shipped one.
// Writes OUT_DIR/<shot>/<arm>-<scheme>-<background>.png and OUT_DIR/<shot>.png (the sheet), and prints
// one JSON line per capture.
//
// A picture not bundled in the repo: an env's background that is not one of env.ts BACKGROUNDS
// (["dark","wallpaper"]) names an outside picture, a JPEG or PNG file given at capture time by
// CMUX_GALLERY_PICTURE_<NAME> (here CMUX_GALLERY_PICTURE_WALLPAPER=/abs/path.jpg), else by the spec's
// "pictures": { "<name>": "<path from the repo root>" } (a file the repo already has). The stage loads
// over the bundled `busy` background (so the page is see-through, as over any picture) and
// frame/background.ts draws this picture in its place, the same way: aspect-filled, then the window
// tint. An env whose picture is not given is left out of the run, with a line saying so. The file
// never goes into the repo: keep a person's own picture on the machine that captures.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { chromium } from "playwright";
import { preview } from "vite";

const spec = JSON.parse(fs.readFileSync(path.resolve(process.argv[2]), "utf8"));
const out = path.resolve(process.argv[3] ?? process.env.FAST_CHECKS_OUT ?? "gallery-state-captures");
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
const allEnvs = spec.envs ?? [
  ["light", "none"],
  ["dark", "none"],
  ["dark", "busy"],
  ["light", "busy"],
];
// The bundled backgrounds (env.ts BACKGROUNDS); any other name is an outside picture (above).
const BUNDLED = new Set(["none", "light", "dark", "busy"]);
/** The pixel size of a JPEG (its SOF segment) or PNG (IHDR), for the aspect fill. */
function pictureSize(bytes) {
  if (bytes.readUInt32BE(0) === 0x89504e47) return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) throw new Error("an outside picture must be a JPEG or a PNG");
  for (let at = 2; at + 9 < bytes.length;) {
    if (bytes[at] !== 0xff) throw new Error("unreadable JPEG");
    const marker = bytes[at + 1];
    const length = bytes.readUInt16BE(at + 2);
    if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker))
      return { width: bytes.readUInt16BE(at + 7), height: bytes.readUInt16BE(at + 5) };
    at += 2 + length;
  }
  throw new Error("a JPEG with no frame size");
}
const pictures = new Map();
for (const [, background] of allEnvs) {
  if (BUNDLED.has(background) || pictures.has(background)) continue;
  const variable = `CMUX_GALLERY_PICTURE_${background.toUpperCase().replace(/[^A-Z0-9]/g, "_")}`;
  const given = process.env[variable];
  const file = given
    ? path.resolve(given)
    : spec.pictures?.[background] && path.resolve(root, "..", spec.pictures[background]);
  if (!file || !fs.existsSync(file)) {
    console.log(JSON.stringify({ background, skipped: `no picture: set ${variable}=/path/to/picture.jpg` }));
    pictures.set(background, null);
    continue;
  }
  const bytes = fs.readFileSync(file);
  const mime = bytes[0] === 0x89 ? "image/png" : "image/jpeg";
  const image = `data:${mime};base64,${bytes.toString("base64")}`;
  pictures.set(background, { name: background, image, ...pictureSize(bytes) });
}
const envs = allEnvs.filter(([, background]) => pictures.get(background) !== null);

const settle = (page) =>
  page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 700)))),
  );

let failures = 0;
const browser = await chromium.launch({ channel: "chrome" }).catch(() => chromium.launch());
try {
  for (const shot of spec.shots) {
    const arms = Object.entries(shot.arms ?? { now: "" });
    const dir = path.join(out, shot.name);
    fs.mkdirSync(dir, { recursive: true });
    const grid = [];
    for (const [arm, css] of arms) {
      const row = [];
      for (const [scheme, background] of envs) {
        const context = await browser.newContext({
          viewport: { width: shot.width ?? 760, height: shot.height ?? 480 },
          deviceScaleFactor: shot.deviceScaleFactor ?? 2,
          colorScheme: scheme,
        });
        const page = await context.newPage();
        const query = new URLSearchParams({
          entry: shot.entry,
          colorScheme: scheme,
          width: shot.widthName ?? "normal",
          frame: shot.frame ?? "component",
        });
        if (shot.variant) query.set("variant", shot.variant);
        if (shot.opts) query.set("opts", shot.opts);
        for (const [key, value] of Object.entries(shot.armQuery?.[arm] ?? {})) query.set(key, String(value));
        const picture = pictures.get(background);
        if (background !== "none") query.set("background", picture ? "busy" : background);
        const file = path.join(dir, `${arm}-${scheme}-${background}.png`);
        try {
          if (picture) await page.addInitScript((value) => (window.cmuxGalleryPicture = value), picture);
          await page.goto(`${baseUrl}/frame.html?${query}`, { waitUntil: "domcontentloaded" });
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          if (css) await page.addStyleTag({ content: css });
          if (shot.setup) await page.evaluate(shot.setup);
          if (shot.hover) await page.locator(shot.hover).first().hover({ timeout: 10_000 });
          await settle(page);
          let clip;
          if (shot.clip) {
            const box = await page.locator(shot.clip).first().boundingBox();
            if (box) {
              const vp = page.viewportSize();
              const m = shot.margin ?? 24;
              const x = Math.max(0, box.x - m);
              const y = Math.max(0, box.y - m);
              clip = {
                x,
                y,
                width: Math.min(vp.width - x, box.width + 2 * m),
                height: Math.min(vp.height - y, box.height + 2 * m),
              };
            }
          }
          await page.screenshot({ path: file, clip });
          row.push(file);
          console.log(JSON.stringify({ shot: shot.name, arm, scheme, background, file: path.relative(out, file) }));
        } catch (error) {
          failures += 1;
          row.push(null);
          console.log(JSON.stringify({ shot: shot.name, arm, scheme, background, error: String(error).slice(0, 300) }));
        }
        await context.close();
      }
      grid.push([arm, row]);
    }
    // The sheet: one row per arm, one column per appearance, labelled.
    const context = await browser.newContext({ viewport: { width: 800, height: 600 } });
    const page = await context.newPage();
    const cells = grid.map(([arm, row]) => [arm, row.map((f) => (f ? fs.readFileSync(f).toString("base64") : null))]);
    // A spec's "sheet": { "scale": 0.5, "caption": "…", "envLabels": { "dark wallpaper": "…" } } (optional):
    // cells drawn at that scale (a 2x capture at 0.5 is one CSS px per sheet px), a caption under the title.
    const sheet = spec.sheet ?? {};
    const labels = envs.map(
      ([s, b]) =>
        sheet.envLabels?.[`${s} ${b}`] ?? (b === "none" ? s : BUNDLED.has(b) ? `${s} over picture` : `${s} over ${b}`),
    );
    const png = await page.evaluate(
      async ([cells, labels, title, scale, caption]) => {
        const load = (src) =>
          src
            ? new Promise((resolve, reject) => {
                const image = new Image();
                image.onload = () => resolve(image);
                image.onerror = reject;
                image.src = `data:image/png;base64,${src}`;
              })
            : Promise.resolve(null);
        const images = await Promise.all(cells.map(async ([arm, row]) => [arm, await Promise.all(row.map(load))]));
        const cw = Math.round(scale * Math.max(1, ...images.flatMap(([, r]) => r.map((i) => i?.width ?? 0))));
        const ch = Math.round(scale * Math.max(1, ...images.flatMap(([, r]) => r.map((i) => i?.height ?? 0))));
        const gap = 16;
        const probe = document.createElement("canvas").getContext("2d");
        probe.font = "600 26px sans-serif";
        const left = 32 + Math.max(88, ...images.map(([arm]) => probe.measureText(arm).width));
        const top = caption ? 104 : 64;
        const canvas = document.createElement("canvas");
        canvas.width = left + labels.length * (cw + gap);
        canvas.height = top + images.length * (ch + gap);
        const g = canvas.getContext("2d");
        g.fillStyle = "#808080";
        g.fillRect(0, 0, canvas.width, canvas.height);
        g.fillStyle = "#fff";
        g.font = "600 26px sans-serif";
        g.fillText(title, 16, 34);
        g.font = "22px sans-serif";
        if (caption) g.fillText(caption, 16, 70);
        labels.forEach((label, c) => g.fillText(label, left + c * (cw + gap), top - 8));
        images.forEach(([arm, row], r) => {
          g.font = "600 26px sans-serif";
          g.fillText(arm, 16, top + r * (ch + gap) + 34);
          row.forEach((image, c) => image && g.drawImage(image, left + c * (cw + gap), top + r * (ch + gap), cw, ch));
        });
        return canvas.toDataURL("image/png").split(",")[1];
      },
      [cells, labels, shot.name, sheet.scale ?? 1, sheet.caption ?? ""],
    );
    fs.writeFileSync(path.join(out, `${shot.name}.png`), Buffer.from(png, "base64"));
    await context.close();
  }
} finally {
  await browser.close();
  await new Promise((resolve, reject) => server.httpServer.close((error) => (error ? reject(error) : resolve())));
}
if (failures) {
  console.error(`${failures} capture(s) failed`);
  process.exitCode = 1;
}
