// The composer's refraction lens (src/ui/glass/composerLens.ts) in real Chromium: under the host's
// Lens mode the composer box bends the transcript under it through a displacement map built once
// per box size. The map is the expensive part, so this file counts builds: a scroll frame or a new
// message changes no size and must build none (only Chromium re-sampling the cached map); a new
// size builds one once it holds; a size seen before builds none. It also checks the bend is there
// (the stripes under the rim move, the middle does not) and that plain mode attaches nothing.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("glass-composer-lens.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");
  const entry = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "glass-composer-lens-")), "entry.ts");
  fs.writeFileSync(
    entry,
    `import * as lens from ${JSON.stringify(path.join(source, "ui/glass/composerLens.ts"))};
     Object.assign(window, { composerLens: lens });`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0]!.text();
  fs.rmSync(path.dirname(entry), { recursive: true, force: true });

  // The box: 320 x 56 at (40, 200), radius 18, over a scroller of 6 px black and white columns (each
  // row a block of them, so a scroll moves the content). No tint and no frost: the pixels are the bend.
  const BOX = { x: 40, y: 200, width: 320, height: 56 };
  const html = (glass: string) =>
    `<!doctype html><html data-glass="${glass}" style="--cmux-surface-background:#fff;--cmux-surface-solid:#fff;--glass-surface:#fff">
     <head><style>${css}
       body { margin: 0; background: #fff }
       .scroller { position: absolute; inset: 0; overflow: auto }
       .row { height: 40px; background: repeating-linear-gradient(90deg, #000 0 6px, #fff 6px 12px) }
       .row:nth-child(even) { background: repeating-linear-gradient(90deg, #fff 0 6px, #000 6px 12px) }
       .box { position: absolute; left: ${BOX.x}px; top: ${BOX.y}px; width: ${BOX.width}px; height: ${BOX.height}px;
         border-radius: 18px; --glass-tint: transparent; --glass-backdrop: none; --glass-rim-shadow: 0 0 transparent;
         --glass-elevation: 0 0 transparent; --composer-lens-tint: transparent; --composer-lens-frost: 0px }
     </style></head>
     <body><div class="scroller">${'<div class="row"></div>'.repeat(200)}</div>
       <div class="box ui-glass ui-glass-material acpmux-composer-box"></div></body></html>`;

  type Stats = { builds: number; hits: number };
  type Lens = {
    watchComposerLens(box: HTMLElement): () => void;
    composerLensStats: Stats;
    resetComposerLensCache(): void;
    SETTLE_MS: number;
  };

  async function open(browser: Browser, glass: string): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 400, height: 300 }, deviceScaleFactor: 1 });
    await page.setContent(html(glass));
    await page.addScriptTag({ content: script });
    await page.evaluate(async () => {
      const lens = (window as unknown as { composerLens: Lens }).composerLens;
      lens.resetComposerLensCache();
      lens.watchComposerLens(document.querySelector<HTMLElement>(".box")!);
      for (let i = 0; i < 5; i++) await new Promise(requestAnimationFrame);
    });
    return page;
  }

  const stats = (page: Page) =>
    page.evaluate(() => ({ ...(window as unknown as { composerLens: Lens }).composerLens.composerLensStats }));
  const lensOn = (page: Page) =>
    page.evaluate(() => document.querySelector(".box")!.hasAttribute("data-composer-lens"));

  /** The red channel along the box's middle row, at every x. */
  async function row(page: Page): Promise<number[]> {
    const png = PNG.sync.read(await page.screenshot());
    const y = BOX.y + BOX.height / 2;
    return Array.from({ length: png.width }, (_, x) => png.data[(y * png.width + x) * 4]!);
  }

  describe("composer lens in chromium", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await chromium.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("plain mode attaches nothing and builds no map", async () => {
      const page = await open(browser, "plain");
      expect(await lensOn(page)).toBe(false);
      expect((await stats(page)).builds).toBe(0);
      expect(await page.evaluate(() => document.querySelectorAll("filter[id^=cmux-composer-lens]").length)).toBe(0);
      await page.close();
    });

    test("lens mode builds the map once; scrolling and new messages only re-sample it", async () => {
      const page = await open(browser, "lens");
      expect(await lensOn(page)).toBe(true);
      expect((await stats(page)).builds).toBe(1);
      // A fast scroll: 120 frames, 9 px a frame, with a message streamed in every tenth frame.
      await page.evaluate(async () => {
        const scroller = document.querySelector<HTMLElement>(".scroller")!;
        for (let frame = 0; frame < 120; frame++) {
          scroller.scrollTop += 9;
          if (frame % 10 === 0) {
            const message = document.createElement("div");
            message.className = "row";
            scroller.append(message);
          }
          await new Promise(requestAnimationFrame);
        }
      });
      expect(await stats(page)).toEqual({ builds: 1, hits: 0 });
      await page.close();
    });

    test("a new size builds once it holds; a size seen before builds nothing", async () => {
      const page = await open(browser, "lens");
      const resize = (width: number) =>
        page.evaluate(async (width) => {
          const lens = (window as unknown as { composerLens: Lens }).composerLens;
          document.querySelector<HTMLElement>(".box")!.style.width = `${width}px`;
          await new Promise((resolve) => setTimeout(resolve, lens.SETTLE_MS + 100));
          for (let i = 0; i < 3; i++) await new Promise(requestAnimationFrame);
        }, width);
      // The box grows through several sizes inside the settle window: one build, for the last.
      await page.evaluate(async () => {
        const box = document.querySelector<HTMLElement>(".box")!;
        for (const width of [324, 328, 332, 336]) {
          box.style.width = `${width}px`;
          await new Promise(requestAnimationFrame);
        }
      });
      await resize(340);
      expect((await stats(page)).builds).toBe(2);
      await resize(BOX.width);
      expect((await stats(page)).builds).toBe(2);
      await resize(340);
      expect((await stats(page)).builds).toBe(2);
      await page.close();
    });

    test("the rim bends the columns under it and the middle does not", async () => {
      const lens = await open(browser, "lens");
      // The reference: the same page with no glass at all, the columns as they are.
      const plain = await open(browser, "plain");
      await plain.evaluate(() => document.querySelector(".box")!.remove());
      const bent = await row(lens);
      const flat = await row(plain);
      await lens.close();
      await plain.close();
      const differs = (from: number, to: number) => {
        let count = 0;
        for (let x = from; x < to; x++) if (Math.abs(bent[x]! - flat[x]!) > 96) count++;
        return count;
      };
      // The left and right bezels (18 px each, past the 18 px corner the middle row is straight).
      // A column moved by the bend shows as a run of flipped pixels at its edge (the rim pulls the
      // columns inward by up to about 8 px; with 12 px columns each bezel flips at least 2).
      expect(differs(BOX.x + 1, BOX.x + 18)).toBeGreaterThan(1);
      expect(differs(BOX.x + BOX.width - 18, BOX.x + BOX.width - 1)).toBeGreaterThan(1);
      expect(differs(BOX.x + 1, BOX.x + 18) + differs(BOX.x + BOX.width - 18, BOX.x + BOX.width - 1)).toBeGreaterThan(
        5,
      );
      // The middle, well past the bezel, is the plain backdrop.
      expect(differs(BOX.x + 60, BOX.x + BOX.width - 60)).toBeLessThan(4);
    });
  });
});
