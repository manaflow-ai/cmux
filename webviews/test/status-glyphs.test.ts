// Leo, 2026-10-14 (the Static status mode, for Reduce Motion): six static status glyphs, told apart by
// shape alone at 10 px, crisp at their exact pixel size, theme-colored and never animated. This loads the
// gallery's contact sheet (ui.status-glyphs) in Chromium at 1x and 2x, light, dark and on a wallpaper,
// and rasterizes each live 10 px glyph at the window's own pixel size with the browser's SVG renderer.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

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
  // The Codex-like set (Leo's team, 2026-10-14): its states' glyphs, in order. A wait is the set's one
  // dot in the attention tint, not a talk bubble (Lawrence, 2026-10-20: "rm the talk icon").
  const CODEX_STATES = ["working", "waiting", "permission", "done", "error"];
  const CODEX = ["idle", "dot", "shieldLine", "dot", "info"];
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
    await warmViteServer(vite, "/gallery/frame.html");
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
  // At 2x the master's straight edges (and a ring's top) sit on pixel boundaries: these pixels, at
  // [x, y, inked], are whole (ink or none). Half a pixel off, each glyph leaves some of them half covered.
  const EDGES_2X: Record<string, [number, number, 0 | 1][]> = {
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
      [10, 3, 0],
      [10, 4, 1],
      [3, 10, 0],
      [4, 10, 1],
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
  };
  /** The probes of `name` that are not whole. */
  const softEdges = (name: string, alpha: number[]) =>
    (EDGES_2X[name] ?? [])
      .filter(([x, y, inked]) => (inked ? alpha[y * 20 + x]! < 215 : alpha[y * 20 + x]! > 40))
      .map(([x, y]) => `${x},${y}=${alpha[y * 20 + x]}`);
  const differ = (a: number[], b: number[]) => a.filter((value, index) => value > 127 !== b[index]! > 127).length;

  for (const [variant, scheme] of [
    ["codex", "light"],
    ["codex", "dark"],
    ["codex-wallpaper", "dark"],
  ] as const) {
    for (const scale of [1, 2]) {
      test(`${variant} ${scheme} @${scale}x: Codex-like line glyphs, a blue done dot, still, apart by shape or tint`, async () => {
        const { pixels, glyphs: drawn } = await glyphs(variant, scheme, scale);
        expect(drawn.map((glyph) => glyph.name)).toEqual(CODEX);
        for (const glyph of drawn) {
          expect(`${glyph.name}: ${glyph.animations} ${glyph.motion}`).toBe(`${glyph.name}: 0 none 0s`);
          expect(`${glyph.name}: ${glyph.color}`).toBe(`${glyph.name}: ${glyph.tint}`);
          if (scale === 1) expect(`${glyph.name} soft ${fuzz(glyph.alpha).toFixed(2)}`).toBe(`${glyph.name} soft 0.00`);
          // Thin line symbols, not filled badges: a line glyph inks under 40% of its square.
          const inked = ink(glyph.alpha).length / (pixels * pixels);
          if (glyph.name !== "dot") expect(`${glyph.name} ink ${inked < 0.4}`).toBe(`${glyph.name} ink true`);
        }
        // Codex's blue for done; a wait's dot is the attention tint, never done's blue; the error's red is
        // the theme's danger color, never the permission grey.
        const color = (state: string) => drawn[CODEX_STATES.indexOf(state)]!.color;
        expect(color("done")).toBe("rgb(57, 130, 245)");
        expect(color("waiting")).not.toBe(color("done"));
        expect(color("error")).not.toBe(color("permission"));
        // The error's ring holds an i the still work ring lacks: 10 whole pixels at 1x, 16 at 2x (a
        // 2x2 dot and a 2x6 stem), and the two differ in color too (grey and red). The wait and done dots
        // are one shape apart by tint alone (checked above). Other pairs: 10 and 30.
        const least = (a: string, b: string) => (scale === 1 ? 10 : [a, b].sort().join("/") === "idle/info" ? 16 : 30);
        for (let i = 0; i < drawn.length; i++) {
          for (let j = i + 1; j < drawn.length; j++) {
            const count = differ(drawn[i]!.alpha, drawn[j]!.alpha);
            if (drawn[i]!.name === drawn[j]!.name) {
              expect(`${CODEX_STATES[i]}/${CODEX_STATES[j]} ${count}`).toBe(`${CODEX_STATES[i]}/${CODEX_STATES[j]} 0`);
              continue;
            }
            expect(`${drawn[i]!.name}/${drawn[j]!.name} ${count >= least(drawn[i]!.name, drawn[j]!.name)}`).toBe(
              `${drawn[i]!.name}/${drawn[j]!.name} true`,
            );
          }
        }
      });
    }
  }

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
          // At 1x every edge falls on a pixel (the pixel art); at 2x the straight edges do and the
          // curves stay smooth.
          if (scale === 1) expect(`${glyph.name} soft ${fuzz(glyph.alpha).toFixed(2)}`).toBe(`${glyph.name} soft 0.00`);
          else expect({ [glyph.name]: softEdges(glyph.name, glyph.alpha) }).toEqual({ [glyph.name]: [] });
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
