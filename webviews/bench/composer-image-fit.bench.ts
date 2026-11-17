// What the composer does with a pasted picture before it is sent, before and after it stopped
// scaling in the page (Leo, "What every coder should know about gamma"; claude-sr2-coord,
// 2026-11-17: "Composer image fit: do it in Rust, not JS"). In Chromium, on the same pictures:
//   before  the old composer/imageWork.ts `fit`: canvas drawImage scaled to 1568 px (an average of
//           sRGB codes), PNG, then the old steps down to 1.5 MiB;
//   after   the new `fit`: drawn one pixel per pixel at its own size, PNG (acpmux then scales it in
//           linear light: cmux-tui acpmux `model_copies::fit_inline`, timed by its own bench test).
// Prints each path's median and best time for a 5K screenshot (paste to a sendable chip), the
// bytes that go to the daemon, and the mean grey of a 1 px checkerboard (127 is the sRGB average,
// 188 its light). With OUT=DIR it writes the before pictures (checkerboard and docs/assets/screenshot.png).
//   [OUT=dir] bun bench/composer-image-fit.bench.ts [rounds=7]
/// <reference types="bun" />
import fs from "node:fs";
import path from "node:path";
import { chromium } from "./browsers";

const ROUNDS = Number(process.argv[2] ?? 7);
const OUT = process.env.OUT;
const SCREENSHOT = path.resolve(import.meta.dir, "../../docs/assets/screenshot.png");

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
await page.setContent("<!doctype html><title>composer image fit</title>");

const real = fs.existsSync(SCREENSHOT) ? fs.readFileSync(SCREENSHOT).toString("base64") : "";

const result = await page.evaluate(
  async ({ rounds, real }) => {
    const MAX_SIDE = 1568;
    const BUDGET = 1536 * 1024;
    const STEPS = [
      { side: MAX_SIDE, quality: 0.9 },
      { side: MAX_SIDE, quality: 0.8 },
      { side: 1200, quality: 0.75 },
      { side: 800, quality: 0.7 },
      { side: 512, quality: 0.6 },
    ];
    // The old composer/imageWork.ts `fit`, as it was.
    async function before(bitmap: ImageBitmap, type: string): Promise<Blob | undefined> {
      const longest = Math.max(bitmap.width, bitmap.height, 1);
      let smallest: Blob | undefined;
      let triedPng = 0;
      for (const step of STEPS) {
        const scale = Math.min(1, step.side / longest);
        const width = Math.max(1, Math.round(bitmap.width * scale));
        const height = Math.max(1, Math.round(bitmap.height * scale));
        if (type !== "image/jpeg" && triedPng !== width) {
          triedPng = width;
          const canvas = new OffscreenCanvas(width, height);
          canvas.getContext("2d")!.drawImage(bitmap, 0, 0, width, height);
          const png = await canvas.convertToBlob({ type: "image/png" });
          if (png.size <= BUDGET) return png;
        }
        const flat = new OffscreenCanvas(width, height);
        const context = flat.getContext("2d")!;
        context.fillStyle = "#fff";
        context.fillRect(0, 0, width, height);
        context.drawImage(bitmap, 0, 0, width, height);
        smallest = await flat.convertToBlob({ type: "image/jpeg", quality: step.quality });
        if (smallest.size <= BUDGET) break;
      }
      return smallest;
    }
    // The new `fit`: its own size, one pixel per pixel.
    async function after(bitmap: ImageBitmap): Promise<Blob> {
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      canvas.getContext("2d")!.drawImage(bitmap, 0, 0);
      return canvas.convertToBlob({ type: "image/png" });
    }
    const b64 = async (blob: Blob) => {
      const bytes = new Uint8Array(await blob.arrayBuffer());
      let binary = "";
      for (let at = 0; at < bytes.length; at += 0x8000)
        binary += String.fromCharCode(...bytes.subarray(at, at + 0x8000));
      return btoa(binary);
    };
    const meanGrey = async (blob: Blob) => {
      const bitmap = await createImageBitmap(blob);
      const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
      const context = canvas.getContext("2d")!;
      context.drawImage(bitmap, 0, 0);
      const data = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
      let sum = 0;
      for (let at = 0; at < data.length; at += 4) sum += data[at]!;
      return { mean: sum / (data.length / 4), width: bitmap.width, height: bitmap.height };
    };
    // A 5K screenshot (5120x2880): a dark gradient with text-like noise over a band, as
    // agent-pane-paste-large-screenshots.test.ts makes them.
    const shot = new OffscreenCanvas(5120, 2880);
    const sc = shot.getContext("2d")!;
    const gradient = sc.createLinearGradient(0, 0, 5120, 2880);
    gradient.addColorStop(0, "#1b1d24");
    gradient.addColorStop(1, "hsl(210, 40%, 40%)");
    sc.fillStyle = gradient;
    sc.fillRect(0, 0, 5120, 2880);
    const noise = sc.getImageData(0, 0, 5120, 900);
    for (let at = 0; at < noise.data.length; at += 4) {
      const value = (Math.random() * 255) | 0;
      noise.data[at] = noise.data[at + 1] = noise.data[at + 2] = value;
      noise.data[at + 3] = 255;
    }
    sc.putImageData(noise, 0, 600);
    const shotFile = new File([await shot.convertToBlob({ type: "image/png" })], "Screenshot.png", {
      type: "image/png",
    });
    // Paste to a sendable chip: decode, then the fit (what the image worker does per paste).
    const time = async (fn: (bitmap: ImageBitmap) => Promise<Blob | undefined>) => {
      const runs: number[] = [];
      let size = 0;
      for (let round = 0; round < rounds; round += 1) {
        const start = performance.now();
        const bitmap = await createImageBitmap(shotFile);
        const blob = await fn(bitmap);
        bitmap.close();
        runs.push(performance.now() - start);
        size = blob?.size ?? 0;
      }
      runs.sort((a, b) => a - b);
      return { median: runs[Math.floor(runs.length / 2)]!, best: runs[0]!, bytes: size };
    };
    const timing = {
      source: shotFile.size,
      before: await time((bitmap) => before(bitmap, "image/png")),
      after: await time((bitmap) => after(bitmap)),
    };
    // A 1 px black and white checkerboard, 3136 px (twice the model's edge).
    const n = 3136;
    const board = new OffscreenCanvas(n, n);
    const bc = board.getContext("2d")!;
    const pixels = bc.createImageData(n, n);
    for (let y = 0; y < n; y += 1)
      for (let x = 0; x < n; x += 1) {
        const at = (y * n + x) * 4;
        const on = (x + y) % 2 === 0 ? 255 : 0;
        pixels.data[at] = pixels.data[at + 1] = pixels.data[at + 2] = on;
        pixels.data[at + 3] = 255;
      }
    bc.putImageData(pixels, 0, 0);
    const boardBitmap = await createImageBitmap(await board.convertToBlob({ type: "image/png" }));
    const boardBefore = (await before(boardBitmap, "image/png"))!;
    const boardAfter = await after(boardBitmap);
    const checker = {
      before: await meanGrey(boardBefore),
      sent: await meanGrey(boardAfter),
      beforePng: await b64(boardBefore),
    };
    let screenshot: { before: string; width: number; height: number } | undefined;
    if (real) {
      const binary = atob(real);
      const bytes = new Uint8Array(binary.length);
      for (let at = 0; at < binary.length; at += 1) bytes[at] = binary.charCodeAt(at);
      const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/png" }));
      const blob = (await before(bitmap, "image/png"))!;
      const size = await meanGrey(blob);
      screenshot = { before: await b64(blob), width: size.width, height: size.height };
    }
    return { timing, checker, screenshot };
  },
  { rounds: ROUNDS, real },
);

await browser.close();
const { timing, checker, screenshot } = result;
const mb = (bytes: number) => (bytes / 1048576).toFixed(2);
console.log(
  `5K screenshot 5120x2880, ${mb(timing.source)} MB PNG; paste to sendable chip (decode + fit), ${ROUNDS} rounds:`,
);
console.log(
  `  before (canvas scale to 1568, sRGB): median ${timing.before.median.toFixed(0)} ms, best ${timing.before.best.toFixed(0)} ms, sends ${mb(timing.before.bytes)} MB`,
);
console.log(
  `  after  (own size, acpmux fits):      median ${timing.after.median.toFixed(0)} ms, best ${timing.after.best.toFixed(0)} ms, sends ${mb(timing.after.bytes)} MB`,
);
console.log(
  `checkerboard 3136 px, 1 px: before ${checker.before.width}x${checker.before.height} mean ${checker.before.mean.toFixed(1)}; after the page sends ${checker.sent.width}x${checker.sent.height} mean ${checker.sent.mean.toFixed(1)} (acpmux makes it 188)`,
);
if (OUT) {
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, "checker-before-browser.png"), Buffer.from(checker.beforePng, "base64"));
  if (screenshot)
    fs.writeFileSync(path.join(OUT, "screenshot-before-browser.png"), Buffer.from(screenshot.before, "base64"));
  fs.writeFileSync(
    path.join(OUT, "composer-image-fit.json"),
    JSON.stringify({ timing, checker: { before: checker.before, sent: checker.sent } }, null, 2),
  );
  console.log(`wrote ${OUT}`);
}
