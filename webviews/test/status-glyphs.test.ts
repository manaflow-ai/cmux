// Leo, 2026-10-14 (the Static status mode, for Reduce Motion): six static status glyphs, told apart by
// shape alone at 10 px, crisp at their exact pixel size, theme-colored and never animated. hq#1957 status
// glyph thunderdome: three sets compete (still, the default; dots; pictograms), and each must hold all of
// that on its own. This loads the gallery's contact sheet (ui.status-glyphs) in Chromium at 1x and 2x,
// light, dark and on a wallpaper, and rasterizes each live 10 px glyph of every set at the window's own
// pixel size with the browser's SVG renderer.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("status-glyphs.test.ts", async () => {
  setDefaultTimeout(120_000);
  const NAMES = ["idle", "working", "waiting", "permission", "done", "error"];
  const SETS = ["still", "dots", "pictograms"];
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

  type Glyph = {
    set: string;
    name: string;
    alpha: number[];
    color: string;
    tint: string;
    animations: number;
    motion: string;
  };

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
          set: svg.dataset.statusGlyphSet!,
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
  // At 2x the master's straight edges (and a ring's top) sit on pixel boundaries: these pixels, at
  // [x, y, inked], are whole (ink or none). Half a pixel off, each glyph leaves some of them half covered.
  // The pictograms' check has no straight edge.
  const EDGES_2X: Record<string, Record<string, [number, number, 0 | 1][]>> = {
    still: {
      idle: [
        [10, 0, 0],
        [10, 1, 1],
        [10, 2, 1],
        [10, 3, 0],
      ],
      working: [
        [9, 9, 0],
        [10, 9, 1],
        [9, 10, 0],
        [10, 10, 1],
      ],
      waiting: [
        [10, 1, 0],
        [10, 2, 1],
        [10, 3, 1],
        [10, 4, 0],
        [0, 8, 0],
        [1, 8, 1],
        [2, 8, 1],
        [3, 8, 0],
      ],
      permission: [
        [1, 6, 0],
        [2, 6, 1],
        [17, 6, 1],
        [18, 6, 0],
      ],
      done: [
        [10, 0, 0],
        [10, 1, 1],
        [0, 10, 0],
        [1, 10, 1],
      ],
      error: [
        [9, 6, 0],
        [10, 6, 0],
        [8, 6, 1],
        [11, 6, 1],
        [9, 11, 1],
        [9, 12, 1],
        [9, 13, 0],
        [10, 14, 0],
      ],
    },
    dots: {
      idle: [
        [10, 1, 0],
        [10, 2, 1],
        [10, 3, 1],
        [10, 4, 0],
      ],
      working: [
        [10, 9, 0],
        [10, 10, 1],
        [5, 9, 0],
        [5, 10, 1],
      ],
      waiting: [
        [10, 2, 1],
        [10, 4, 0],
        [10, 5, 0],
        [10, 6, 1],
      ],
      permission: [
        [7, 10, 1],
        [8, 10, 0],
        [11, 10, 0],
        [12, 10, 1],
        [10, 3, 1],
        [10, 4, 0],
        [10, 15, 0],
        [10, 16, 1],
      ],
      done: [
        [10, 1, 0],
        [10, 2, 1],
        [1, 10, 0],
        [2, 10, 1],
      ],
      error: [
        [10, 1, 0],
        [10, 2, 1],
        [1, 10, 0],
        [2, 10, 1],
      ],
    },
    pictograms: {
      idle: [
        [0, 10, 0],
        [1, 10, 1],
        [10, 18, 1],
        [10, 19, 0],
      ],
      working: [
        [10, 0, 1],
        [10, 1, 1],
        [10, 2, 0],
        [19, 19, 1],
      ],
      waiting: [
        [10, 1, 0],
        [10, 2, 1],
        [10, 5, 1],
        [10, 13, 1],
        [10, 14, 0],
        [0, 8, 1],
        [1, 8, 1],
      ],
      permission: [
        [1, 15, 0],
        [2, 15, 1],
        [17, 15, 1],
        [18, 15, 0],
        [7, 13, 1],
        [8, 13, 0],
        [11, 13, 0],
        [12, 13, 1],
        [3, 7, 0],
        [4, 7, 1],
        [5, 7, 1],
        [6, 7, 0],
      ],
      done: [],
      error: [
        [8, 8, 1],
        [9, 8, 0],
        [10, 8, 0],
        [11, 8, 1],
        [9, 5, 1],
        [9, 6, 0],
        [9, 12, 1],
        [9, 13, 1],
        [9, 14, 0],
        [9, 16, 1],
      ],
    },
  };
  /** The probes of `name` in `set` that are not whole. */
  const softEdges = (set: string, name: string, alpha: number[]) =>
    (EDGES_2X[set]?.[name] ?? [])
      .filter(([x, y, inked]) => (inked ? alpha[y * 20 + x]! < 215 : alpha[y * 20 + x]! > 40))
      .map(([x, y]) => `${x},${y}=${alpha[y * 20 + x]}`);
  const differ = (a: number[], b: number[]) => a.filter((value, index) => value > 127 !== b[index]! > 127).length;

  for (const [variant, scheme] of [
    ["sheet", "light"],
    ["sheet", "dark"],
    ["wallpaper", "dark"],
  ] as const) {
    for (const scale of [1, 2]) {
      test(`${variant} ${scheme} @${scale}x: every set's six static glyphs, apart by shape, crisp, still, theme-colored`, async () => {
        const { pixels, glyphs: all } = await glyphs(variant, scheme, scale);
        expect(pixels).toBe(10 * scale);
        expect([...new Set(all.map((glyph) => glyph.set))].sort()).toEqual([...SETS].sort());
        for (const set of SETS) {
          const drawn = all.filter((glyph) => glyph.set === set);
          expect({ [set]: drawn.map((glyph) => glyph.name) }).toEqual({ [set]: NAMES });
          for (const glyph of drawn) {
            const id = `${set} ${glyph.name}`;
            // Never animated: no running animation, no transition.
            expect(`${id}: ${glyph.animations} ${glyph.motion}`).toBe(`${id}: 0 none 0s`);
            // Tinted by its theme role, the same role in every set.
            expect(`${id}: ${glyph.color}`).toBe(`${id}: ${glyph.tint}`);
            const still = all.find((other) => other.set === SETS[0] && other.name === glyph.name)!;
            expect(`${id}: ${glyph.tint}`).toBe(`${id}: ${still.tint}`);
            // At 1x every edge falls on a pixel (the pixel art); at 2x the straight edges do and the
            // curves stay smooth.
            if (scale === 1) expect(`${id} soft ${fuzz(glyph.alpha).toFixed(2)}`).toBe(`${id} soft 0.00`);
            else expect({ [id]: softEdges(set, glyph.name, glyph.alpha) }).toEqual({ [id]: [] });
          }
          // Apart by shape alone: every pair differs in enough whole pixels.
          const least = scale === 1 ? 12 : 30;
          for (let i = 0; i < drawn.length; i++) {
            for (let j = i + 1; j < drawn.length; j++) {
              const count = differ(drawn[i]!.alpha, drawn[j]!.alpha);
              const pair = `${set} ${drawn[i]!.name}/${drawn[j]!.name}`;
              expect(`${pair} ${count >= least}`).toBe(`${pair} true`);
            }
          }
        }
      });
    }
  }
});
