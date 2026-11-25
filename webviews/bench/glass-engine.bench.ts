// l10n-allow-file: bench fixture text, not shipped UI.
// What one frame of web glass costs on the GPU, the lens as it ships against the glass engine
// (src/ui/glass/engine), in one harness: a 1440 x 900 page at 2x over a wallpaper still with the
// art's blur, a composer, a menu and GLASS small glass (the chips and pills of a busy pane). For each
// renderer, glass mode (lens, spectrum) and art blur it draws ROUNDS x 120 frames back to back and
// reads back after the last, so the GPU finished them all (glassLensDrawCost), and prints p50 / p95 / p99 of the per-frame ms over the rounds, and how many
// panes redrawing in the same frame fit a 120 Hz frame (8.33 ms) at p95.
//   bun bench/glass-engine.bench.ts [rounds=20]
// BROWSER=chromium|webkit (default chromium); GLASS (default 30); LABEL names the run.
/// <reference types="bun" />
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit } from "./browsers";

const ROUNDS = Number(process.argv[2] ?? 20);
const GLASS = Number(process.env.GLASS ?? 30);
const BROWSER = process.env.BROWSER ?? "chromium";
const LABEL = process.env.LABEL ?? "run";
const source = path.resolve(import.meta.dir, "../src");
const log = (...args: unknown[]) => console.error("glass-engine:", ...args);

const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
  .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
  .join("\n");
const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glass-engine-bench-")), "entry.ts");
fs.writeFileSync(
  entry,
  `import { installGlassLens, glassLensState, glassLensDrawCost } from ${JSON.stringify(path.join(source, "ui/glass/lens.ts"))};
   Object.assign(window, { installGlassLens, glassLensState, glassLensDrawCost });`,
);
const built = await Bun.build({ entrypoints: [entry], target: "browser" });
if (!built.success) throw new Error(built.logs.join("\n"));
const script = await built.outputs[0]!.text();
fs.rmSync(path.dirname(entry), { recursive: true, force: true });
const wallpaper = fs
  .readFileSync(path.join(source, "gallery/fixtures/assets/liquid-glass-wallpaper.jpg"))
  .toString("base64");

const chips = Array.from(
  { length: GLASS },
  (_, i) =>
    `<div class="ui-glass" style="position:absolute;left:${24 + (i % 10) * 138}px;top:${150 + Math.floor(i / 10) * 70}px;width:120px;height:48px;border-radius:${i % 3 ? 12 : 24}px"></div>`,
).join("");
const html = (engine: boolean, mode: string) =>
  `<!doctype html><html data-glass="${mode}" ${engine ? "data-glass-engine" : ""} style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,31,36);--cmux-text:rgb(236,236,240)">
   <head><style>${css} body{margin:0}</style></head><body>
   <div class="ui-glass" style="position:absolute;right:60px;top:30px;width:220px;height:150px;border-radius:12px"></div>
   ${chips}
   <div class="ui-glass" style="position:absolute;left:28px;right:28px;bottom:28px;height:120px;border-radius:22px"></div>
   </body></html>`;

function percentile(values: number[], p: number): number {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length))]!;
}

const type = BROWSER === "webkit" ? webkit : chromium;
const browser = await type.launch({
  headless: true,
  // On a Mac, headless Chromium draws WebGL on the GPU (Metal) as the app does.
  args:
    BROWSER === "webkit" || process.platform !== "darwin"
      ? []
      : ["--enable-gpu", "--use-angle=metal", "--ignore-gpu-blocklist"],
});
const results: Record<string, unknown>[] = [];
for (const [mode, blur] of [
  ["lens", 0],
  ["lens", 24],
  ["spectrum", 24],
] as const) {
  for (const engine of [false, true]) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
    await page.setContent(html(engine, mode));
    await page.addScriptTag({ content: script });
    const renderer = await page.evaluate(
      async ({ image, blur }) => {
        const root = document.documentElement;
        root.style.setProperty(
          "background",
          `url(data:image/jpeg;base64,${image}) 0 0 / 100vw 100vh no-repeat fixed`,
          "important",
        );
        const host = window as unknown as {
          installGlassLens(doc: Document): void;
          cmuxTheme: { backdrop(partial: unknown): void };
        };
        host.installGlassLens(document);
        host.cmuxTheme.backdrop({
          image: `data:image/jpeg;base64,${image}`,
          key: "bench",
          rect: { x: 0, y: 0, width: innerWidth, height: innerHeight },
          blur,
          tint: "rgba(0,0,0,0.18)",
        });
        for (let i = 0; i < 40; i++) await new Promise(requestAnimationFrame);
        const gl = document.createElement("canvas").getContext("webgl");
        const info = gl?.getExtension("WEBGL_debug_renderer_info");
        return info && gl ? String(gl.getParameter(info.UNMASKED_RENDERER_WEBGL)) : "unknown";
      },
      { image: wallpaper, blur },
    );
    const state = await page.evaluate(() =>
      (
        window as unknown as { glassLensState(): { drawing: boolean; engine: boolean; rects: number } }
      ).glassLensState(),
    );
    if (!state.drawing || state.engine !== engine) throw new Error(`not drawing as asked: ${JSON.stringify(state)}`);
    // Warm up, then the rounds.
    await page.evaluate(() =>
      (window as unknown as { glassLensDrawCost(d?: Document, n?: number): number }).glassLensDrawCost(document, 20),
    );
    const samples: number[] = [];
    for (let round = 0; round < ROUNDS; round++)
      samples.push(
        await page.evaluate(() =>
          (window as unknown as { glassLensDrawCost(d?: Document, n?: number): number }).glassLensDrawCost(
            document,
            120,
          ),
        ),
      );
    const p95 = percentile(samples, 95);
    const row = {
      label: LABEL,
      browser: BROWSER,
      gpu: renderer,
      renderer: engine ? "engine" : "lens",
      mode,
      artBlur: blur,
      glass: state.rects,
      p50: +percentile(samples, 50).toFixed(3),
      p95: +p95.toFixed(3),
      p99: +percentile(samples, 99).toFixed(3),
      panesAt120Hz: Math.floor(8.33 / p95),
    };
    results.push(row);
    log(JSON.stringify(row));
    await page.close();
  }
}
await browser.close();
console.log(JSON.stringify(results, null, 2));
