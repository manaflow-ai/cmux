// Leo, 2026-10-14 (the Static status mode, for Reduce Motion): six static status glyphs, told apart by
// shape alone at 10 px, crisp at their exact pixel size, theme-colored and never animated. This loads the
// gallery's contact sheet (ui.status-glyphs) in Chromium at 1x and 2x, light, dark and on a wallpaper,
// and rasterizes each live 10 px glyph at the window's own pixel size with the browser's SVG renderer.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("status-glyphs.test.ts", async () => {
  setDefaultTimeout(120_000);
  const NAMES = ["idle", "working", "waiting", "permission", "done", "error"];
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("status-glyphs: skipping (run `bunx playwright install chromium`)");
    describe.skip("status glyphs", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string, scheme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/gallery/frame.html?entry=ui.status-glyphs&variant=${variant}&colorScheme=${scheme}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      // No file watcher: the test edits nothing, and a shared host can be out of inotify watches.
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Glyph = { name: string; alpha: number[]; color: string; tint: string; animations: number; motion: string };

  /** Each live 10 px glyph of the sheet, rasterized at the window's pixel size. */
  async function glyphs(variant: string, scheme: string, scale: number): Promise<{ pixels: number; glyphs: Glyph[] }> {
    const page = await browser!.newPage({ viewport: { width: 720, height: 640 }, deviceScaleFactor: scale });
    await page.goto(url(variant, scheme));
    // Vite can reload the stage once while it optimizes a dependency on the first load.
    const ready = () =>
      page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, { timeout: 30_000 });
    await ready().catch(async () => {
      await page.reload();
      await ready();
    });
    const result = await page.evaluate(async () => {
      const pixels = Math.round(10 * window.devicePixelRatio);
      const out: Glyph[] = [];
      for (const svg of Array.from(
        document.querySelectorAll<SVGSVGElement>(".status-glyphs-live [data-status-glyph]"),
      )) {
        const style = getComputedStyle(svg);
        const probe = document.createElement("span");
        probe.style.color = svg.dataset.tint ?? "";
        svg.parentElement!.append(probe);
        const tint = getComputedStyle(probe).color;
        probe.remove();
        // The browser's own SVG rasterizer, at the glyph's device pixel size, in black.
        const copy = svg.cloneNode(true) as SVGSVGElement;
        copy.setAttribute("xmlns", "http://www.w3.org/2000/svg");
        copy.setAttribute("width", String(pixels));
        copy.setAttribute("height", String(pixels));
        copy.style.color = "black";
        const image = new Image();
        image.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(copy.outerHTML)}`;
        await image.decode();
        const canvas = document.createElement("canvas");
        canvas.width = canvas.height = pixels;
        const context = canvas.getContext("2d")!;
        context.drawImage(image, 0, 0, pixels, pixels);
        const data = context.getImageData(0, 0, pixels, pixels).data;
        const alpha: number[] = [];
        for (let index = 3; index < data.length; index += 4) alpha.push(data[index]!);
        const motion = [style.animationName, style.transitionDuration].join(" ");
        out.push({
          name: svg.dataset.statusGlyph!,
          alpha,
          color: style.color,
          tint,
          animations: svg.getAnimations({ subtree: true }).length,
          motion,
        });
      }
      return { pixels, glyphs: out };
    });
    await page.close();
    return result;
  }

  const ink = (alpha: number[]) => alpha.filter((value) => value > 20);
  /** Ink pixels only partly covered: soft edges. */
  const fuzz = (alpha: number[]) => ink(alpha).filter((value) => value < 235).length / Math.max(1, ink(alpha).length);
  const differ = (a: number[], b: number[]) => a.filter((value, index) => value > 127 !== b[index]! > 127).length;

  for (const [variant, scheme] of [
    ["sheet", "light"],
    ["sheet", "dark"],
    ["wallpaper", "dark"],
  ] as const) {
    for (const scale of [1, 2]) {
      test(`${variant} ${scheme} @${scale}x: six static glyphs, apart by shape, crisp, still, theme-colored`, async () => {
        const { pixels, glyphs: drawn } = await glyphs(variant, scheme, scale);
        expect(pixels).toBe(10 * scale);
        expect(drawn.map((glyph) => glyph.name)).toEqual(NAMES);
        for (const glyph of drawn) {
          // Never animated: no running animation, no transition.
          expect(`${glyph.name}: ${glyph.animations} ${glyph.motion}`).toBe(`${glyph.name}: 0 none 0s`);
          // Tinted by its theme role.
          expect(`${glyph.name}: ${glyph.color}`).toBe(`${glyph.name}: ${glyph.tint}`);
          // At 1x every edge falls on a pixel; at 2x the straight edges do and the curves stay smooth.
          const soft = fuzz(glyph.alpha);
          expect(`${glyph.name} soft ${soft.toFixed(2)}`).toBe(
            `${glyph.name} soft ${(scale === 1 ? 0 : Math.min(soft, 0.6)).toFixed(2)}`,
          );
        }
        // Apart by shape alone: every pair differs in enough whole pixels.
        const least = scale === 1 ? 12 : 30;
        for (let i = 0; i < drawn.length; i++) {
          for (let j = i + 1; j < drawn.length; j++) {
            const count = differ(drawn[i]!.alpha, drawn[j]!.alpha);
            expect(`${drawn[i]!.name}/${drawn[j]!.name} ${count >= least}`).toBe(
              `${drawn[i]!.name}/${drawn[j]!.name} true`,
            );
          }
        }
      });
    }
  }
});
