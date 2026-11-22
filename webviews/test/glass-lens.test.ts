// The liquid glass lens (src/ui/glass/lens.ts, plans/cmux-next/glass-lens-DESIGN.md) in real
// Chromium and WebKit: the page paints a striped wallpaper as the app's native backdrop would, the
// host's still of it goes through cmuxTheme.backdrop, and the screenshot shows the stripes bent
// near the rim of a `.ui-glass` box in lens mode, and untouched (with no canvas at all) in plain
// mode and under the host's Reduce Transparency. The box's own tint, blur and rim are cleared so
// the pixels are the lens's alone.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("glass-lens.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");

  const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glass-lens-")), "entry.ts");
  fs.writeFileSync(
    entry,
    `import { installGlassLens, glassLensState, glassShaderSources } from ${JSON.stringify(path.join(source, "ui/glass/lens.ts"))};
     Object.assign(window, { installGlassLens, glassLensState, glassShaderSources });`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0]!.text();
  fs.rmSync(path.dirname(entry), { recursive: true, force: true });

  // The box: 240 x 120 at (80, 60), radius 24, no tint, frost, rim or own blur.
  const BOX = { x: 80, y: 60, width: 240, height: 120 };
  const html = (glass: string, extra = "") =>
    `<!doctype html><html data-glass="${glass}" ${extra} style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,30,30)">
     <head><style>${css}
       body { margin: 0 }
       .box { position: absolute; left: ${BOX.x}px; top: ${BOX.y}px; width: ${BOX.width}px; height: ${BOX.height}px;
         border-radius: 24px; --glass-tint: transparent; --glass-backdrop: none; --glass-rim-shadow: 0 0 transparent;
         --glass-blur: 0px; --glass-refraction: 18px; background: transparent; }
     </style></head><body><div class="box ui-glass"></div></body></html>`;

  /** Paints 6 px black and white stripes as the page background and sends the same still. */
  async function open(browser: Browser, glass: string, extra = ""): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 400, height: 240 }, deviceScaleFactor: 1 });
    await page.setContent(html(glass, extra));
    await page.addScriptTag({ content: script });
    await page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = innerWidth;
      canvas.height = innerHeight;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#fff";
      context.fillRect(0, 0, canvas.width, canvas.height);
      context.fillStyle = "#000";
      for (let x = 0; x < canvas.width; x += 12) context.fillRect(x, 0, 6, canvas.height);
      const image = canvas.toDataURL("image/png");
      const root = document.documentElement;
      root.style.setProperty("background", `url(${image}) 0 0 / 100vw 100vh no-repeat fixed`, "important");
      const host = window as unknown as {
        installGlassLens(doc: Document): void;
        cmuxTheme: { backdrop(partial: unknown): void };
      };
      host.installGlassLens(document);
      host.cmuxTheme.backdrop({
        image,
        key: "stripes",
        rect: { x: 0, y: 0, width: innerWidth, height: innerHeight },
        blur: 0,
        tint: "transparent",
      });
      // The still decodes, uploads, then the next frames draw.
      for (let i = 0; i < 30; i++) await new Promise(requestAnimationFrame);
    });
    return page;
  }

  /** The red channel along a row, by default the box's middle one. */
  async function row(page: Page, y = BOX.y + BOX.height / 2): Promise<number[]> {
    const png = PNG.sync.read(await page.screenshot());
    const values: number[] = [];
    for (let x = 0; x < png.width; x++) values.push(png.data[(y * png.width + x) * 4]!);
    return values;
  }

  const meanDifference = (a: number[], b: number[], from: number, to: number) => {
    let sum = 0;
    for (let x = from; x < to; x++) sum += Math.abs(a[x]! - b[x]!);
    return sum / (to - from);
  };

  const state = (page: Page) =>
    page.evaluate(() =>
      (window as unknown as { glassLensState(): { drawing: boolean; running: boolean } }).glassLensState(),
    );
  const canvases = (page: Page) =>
    page.evaluate(() => document.querySelectorAll("canvas[data-cmux-glass-lens]").length);

  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    describe(`glass lens in ${name}`, () => {
      let browser: Browser;
      let webgl = true;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
        const page = await browser.newPage();
        webgl = await page.evaluate(() => {
          const canvas = document.createElement("canvas");
          return Boolean(canvas.getContext("webgl2") ?? canvas.getContext("webgl"));
        });
        await page.close();
        if (!webgl) console.warn(`glass-lens: ${name} has no WebGL here; only the inert paths are checked`);
      });
      afterAll(async () => browser?.close());

      // Every dialect the lens can pick compiles and links where its context exists: WebGL2's
      // textureLod, WebGL1 with EXT_shader_texture_lod, and plain WebGL1's biased texture2D.
      test("every shader dialect compiles and links", async () => {
        if (!webgl) return;
        const page = await browser.newPage();
        await page.setContent(`<!doctype html><script>${script}</script>`);
        const results = await page.evaluate(() => {
          type Sources = { vertex: string; fragment: string };
          const sources = (window as unknown as { glassShaderSources: (dialect: string) => Sources })
            .glassShaderSources;
          const build = (gl: WebGLRenderingContext, dialect: string) => {
            const { vertex, fragment } = sources(dialect);
            const program = gl.createProgram()!;
            for (const [type, text] of [
              [gl.VERTEX_SHADER, vertex],
              [gl.FRAGMENT_SHADER, fragment],
            ] as const) {
              const shader = gl.createShader(type)!;
              gl.shaderSource(shader, text);
              gl.compileShader(shader);
              if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS))
                return `${dialect}: ${gl.getShaderInfoLog(shader)}`;
              gl.attachShader(program, shader);
            }
            gl.linkProgram(program);
            return gl.getProgramParameter(program, gl.LINK_STATUS)
              ? "ok"
              : `${dialect}: ${gl.getProgramInfoLog(program)}`;
          };
          const out: Record<string, string> = {};
          const gl2 = document.createElement("canvas").getContext("webgl2");
          if (gl2) out.webgl2 = build(gl2, "webgl2");
          const gl1 = document.createElement("canvas").getContext("webgl");
          if (gl1) {
            out.webgl1 = build(gl1, "webgl1");
            if (gl1.getExtension("EXT_shader_texture_lod")) out["webgl1-lod"] = build(gl1, "webgl1-lod");
          }
          return out;
        });
        await page.close();
        expect(Object.keys(results).length).toBeGreaterThan(0);
        for (const [dialect, result] of Object.entries(results)) expect(`${dialect} ${result}`).toBe(`${dialect} ok`);
      });

      test("plain glass draws no canvas and leaves the wallpaper as it is", async () => {
        const page = await open(browser, "plain");
        expect(await canvases(page)).toBe(0);
        expect((await state(page)).running).toBe(false);
        const values = await row(page);
        // Unbent: the stripes keep their 6 px period across the box.
        for (let x = BOX.x + 2; x < BOX.x + 40; x++) expect(values[x]! > 127).toBe(Math.floor(x / 6) % 2 === 1);
        await page.close();
      });

      test("Reduce Transparency from the host is plain: no canvas", async () => {
        const page = await open(browser, "lens", "data-reduce-transparency");
        expect(await canvases(page)).toBe(0);
        expect((await state(page)).running).toBe(false);
        await page.close();
      });

      // The sidebar's Updated card (surface.tsx): the host draws the glass natively under the page,
      // so the lens draws nothing over it, from the start or once the page says so.
      test("a page whose host draws its glass (data-glass-native) gets no lens", async () => {
        const page = await open(browser, "lens", "data-glass-native");
        expect(await canvases(page)).toBe(0);
        expect((await state(page)).running).toBe(false);
        await page.close();
        if (!webgl) return;
        const later = await open(browser, "lens");
        expect(await canvases(later)).toBe(1);
        await later.evaluate(() => document.documentElement.setAttribute("data-glass-native", ""));
        await later.evaluate(() => new Promise(requestAnimationFrame));
        expect(await canvases(later)).toBe(0);
        expect((await state(later)).running).toBe(false);
        await later.close();
      });

      test("lens glass bends the stripes at the rim and leaves the center", async () => {
        if (!webgl) return;
        const page = await open(browser, "lens");
        expect(await canvases(page)).toBe(1);
        expect((await state(page)).drawing).toBe(true);
        const lens = await row(page);
        await page.evaluate(() => document.documentElement.setAttribute("data-glass", "plain"));
        await page.evaluate(() => new Promise(requestAnimationFrame));
        expect(await canvases(page)).toBe(0);
        // Linux WebKit's headless compositor leaves WebGL out of screenshots (CI, 2026-10-21: the
        // lens drew, the pixels matched plain): there the state above is the check.
        if (name === "webkit" && process.platform === "linux") {
          await page.close();
          return;
        }
        const plain = await row(page);
        // Inside the left rim band the sample comes from up to 18 px further in: the stripes move.
        expect(meanDifference(lens, plain, BOX.x + 1, BOX.x + 24)).toBeGreaterThan(40);
        expect(meanDifference(lens, plain, BOX.x + BOX.width - 24, BOX.x + BOX.width - 1)).toBeGreaterThan(40);
        // Past the band (54 px) nothing bends, and outside the glass the copy matches the page.
        const center = BOX.x + BOX.width / 2;
        expect(meanDifference(lens, plain, center - 30, center + 30)).toBeLessThan(25);
        expect(meanDifference(lens, plain, 4, BOX.x - 4)).toBeLessThan(25);
        await page.close();
      });

      test("the gloss (--glass-gloss) lights the top rim and leaves the center", async () => {
        if (!webgl) return;
        const page = await open(browser, "lens");
        // Linux WebKit's headless compositor leaves WebGL out of screenshots (above).
        if (name === "webkit" && process.platform === "linux") {
          await page.close();
          return;
        }
        const setGloss = (gloss: string) =>
          page.evaluate(async (value) => {
            const box = document.querySelector<HTMLElement>(".box")!;
            box.style.setProperty("--glass-gloss", value);
            // A class change marks the surface stale, so the lens reads its tokens again.
            box.classList.toggle("relit");
            for (let i = 0; i < 10; i++) await new Promise(requestAnimationFrame);
          }, gloss);
        await setGloss("0");
        const topDark = await row(page, BOX.y + 2);
        const midDark = await row(page);
        await setGloss("1");
        const topLit = await row(page, BOX.y + 2);
        const midLit = await row(page);
        await page.close();
        const center = BOX.x + BOX.width / 2;
        // Two px under the top edge the rim faces the light: the black stripes there brighten.
        expect(meanDifference(topLit, topDark, center - 40, center + 40)).toBeGreaterThan(25);
        // The middle of the glass is past the rim: no light there.
        expect(meanDifference(midLit, midDark, center - 30, center + 30)).toBeLessThan(5);
      });

      test("a joined edge (--glass-join) bends no rim: the side band runs straight up to it", async () => {
        if (!webgl) return;
        const page = await open(browser, "lens");
        // Linux WebKit's headless compositor leaves WebGL out of screenshots (above).
        if (name === "webkit" && process.platform === "linux") {
          await page.close();
          return;
        }
        // Two px under the top edge, in the left corner: outside the 24 px rounded corner the lens
        // leaves the wallpaper as it is.
        const y = BOX.y + 2;
        const rounded = await row(page, y);
        await page.evaluate(async () => {
          const style = document.createElement("style");
          style.textContent = ".box.joined { --glass-join: top; }";
          document.head.append(style);
          document.querySelector(".box")!.classList.add("joined");
          for (let i = 0; i < 10; i++) await new Promise(requestAnimationFrame);
        });
        const joined = await row(page, y);
        const joinedAbove = await row(page, BOX.y - 4);
        await page.evaluate(() => document.documentElement.setAttribute("data-glass", "plain"));
        await page.evaluate(() => new Promise(requestAnimationFrame));
        const plain = await row(page, y);
        const plainAbove = await row(page, BOX.y - 4);
        await page.close();
        expect(meanDifference(rounded, plain, BOX.x + 1, BOX.x + 8)).toBeLessThan(25);
        // Joined at the top, the corner is square and the left band bends there as at mid-height.
        expect(meanDifference(joined, plain, BOX.x + 1, BOX.x + 8)).toBeGreaterThan(40);
        // The glass stops at the joined edge: above it the copy matches the page.
        expect(meanDifference(joinedAbove, plainAbove, BOX.x + 1, BOX.x + BOX.width - 1)).toBeLessThan(25);
      });

      test("the loop draws only when a rect changes, then stops", async () => {
        if (!webgl) return;
        const page = await open(browser, "lens");
        const draws = () =>
          page.evaluate(() => (window as unknown as { glassLensState(): { draws: number } }).glassLensState().draws);
        const frames = (count: number) =>
          page.evaluate(async (n) => {
            for (let i = 0; i < n; i++) await new Promise(requestAnimationFrame);
          }, count);
        const settled = await draws();
        await frames(40);
        expect(await draws()).toBe(settled);
        // An inline move: no scroll, no class, no resize.
        await page.evaluate(() => {
          (document.querySelector(".ui-glass") as HTMLElement).style.left = "90px";
        });
        await frames(5);
        expect(await draws()).toBe(settled + 1);
        await frames(40);
        expect(await draws()).toBe(settled + 1);
        await page.close();
      });

      test("the lens stops and removes its canvas when the glass leaves", async () => {
        if (!webgl) return;
        const page = await open(browser, "lens");
        expect(await canvases(page)).toBe(1);
        await page.evaluate(() => document.querySelector(".ui-glass")!.remove());
        await page.evaluate(() => new Promise(requestAnimationFrame));
        expect(await canvases(page)).toBe(0);
        expect(await page.evaluate(() => document.documentElement.hasAttribute("data-glass-lens"))).toBe(false);
        await page.close();
      });
    });
  }
});
