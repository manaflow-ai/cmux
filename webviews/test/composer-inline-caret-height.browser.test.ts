// The caret on a line with a pasted image is the text's height (#40941: "after pasting an image
// the text caret becomes very tall: it extends far above the line of text being typed"). Measured on
// the painted caret: the field's caret is drawn magenta and found in screenshots, in both of the
// lane's engines (WebKit is the app's, and the one whose native caret ran the thumbnail's height),
// beside the chip and inside the words after it.
// cmux-web-test-timeout: 600
import { expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-caret-height.browser.test.ts", async () => {
  setDefaultTimeout(600_000);

  const ENTRY = "agent-pane.composer";
  const WIDTH = 1280;
  /// "Compare this " then the screenshot (one position), then "with the previous result.".
  const AFTER_CHIP = "Compare this ".length + 1;
  const IN_WORDS = AFTER_CHIP + "with".length;
  /// How much taller than the text's line the painted caret may be, in CSS px (whole-pixel painting).
  const TOLERANCE = 2;

  const nextFrames = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done) => {
          let left = 4;
          // raf-read: reads nothing; it only lets four frames pass before the next screenshot.
          const tick = () => (--left ? requestAnimationFrame(tick) : done());
          requestAnimationFrame(tick);
        }),
    );

  /// The painted caret's rows (CSS px) inside `band`, read from screenshots until a blink shows it
  /// at the same place twice in a row.
  async function caretRows(page: Page, band: { left: number; right: number; top: number; bottom: number }) {
    const scale = await page.evaluate(() => window.devicePixelRatio);
    const clip = { x: band.left, y: band.top, width: band.right - band.left, height: band.bottom - band.top };
    let last: { top: number; bottom: number } | undefined;
    for (let attempt = 0; attempt < 60; attempt++) {
      const shot = PNG.sync.read(await page.screenshot({ clip, caret: "initial", scale: "device" }));
      const rows = new Set<number>();
      for (let at = 0; at < shot.data.length; at += 4) {
        const [r, g, b] = [shot.data[at]!, shot.data[at + 1]!, shot.data[at + 2]!];
        if (r > 215 && g < 60 && b > 215) rows.add(Math.floor(at / 4 / shot.width));
      }
      if (rows.size) {
        const ys = [...rows];
        const seen = { top: band.top + Math.min(...ys) / scale, bottom: band.top + (Math.max(...ys) + 1) / scale };
        if (last && last.top === seen.top && last.bottom === seen.bottom) return seen;
        last = seen;
      }
      await nextFrames(page);
    }
    throw new Error(last ? `the caret never held still (last at ${last.top})` : "the caret never showed");
  }

  const caretAt = async (page: Page, offset: number) => {
    const set = (at: number) =>
      page.evaluate((to) => {
        const field = document.querySelector(".acpmux-md-field") as HTMLElement & {
          acpmuxMarkdownField?: { setCaret(offset: number): void; focus(): void };
        };
        field.acpmuxMarkdownField!.focus();
        field.acpmuxMarkdownField!.setCaret(to);
      }, at);
    await set(0);
    await nextFrames(page);
    await set(offset);
    await nextFrames(page);
  };

  const layout = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-md [data-inline-attachment]")!;
      const paragraph = node.closest("p")!;
      const box = paragraph.getBoundingClientRect();
      const field = paragraph.closest(".acpmux-md-field")!.getBoundingClientRect();
      const scale = box.width / paragraph.offsetWidth;
      return {
        band: {
          left: Math.max(0, field.left),
          right: Math.min(innerWidth, field.right),
          top: Math.max(0, box.top - 4),
          bottom: Math.min(innerHeight, box.bottom + 4),
        },
        lineHeight: parseFloat(getComputedStyle(paragraph).lineHeight) * scale,
        chipHeight: node.getBoundingClientRect().height,
      };
    });

  const run = async (engine: "chromium" | "webkit", launch: () => Promise<Browser>) => {
    const { createServer } = await import("vite");
    const vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    const browser = await launch();
    const failures: string[] = [];
    const report: string[] = [];
    try {
      await vite.listen();
      await warmGalleryFrame(vite, ENTRY, engine === "chromium" ? { browser } : {});
      const port = (vite.httpServer!.address() as { port: number }).port;
      for (const scene of [
        {
          name: "single",
          variant: "attachment-inline-caret",
          width: WIDTH,
          scale: 1,
          offsets: [2, AFTER_CHIP - 1, AFTER_CHIP, IN_WORDS],
        },
        {
          name: "pair",
          variant: "attachment-inline-reorder",
          width: WIDTH,
          scale: 1,
          offsets: [
            2,
            "Which layout reads better?".length,
            "Which layout reads better?".length + 1,
            "Which layout reads better?".length + 2,
          ],
        },
        {
          name: "wrapped-pair",
          variant: "attachment-inline-reorder",
          width: 360,
          scale: 1,
          offsets: [
            2,
            "Which layout reads better?".length,
            "Which layout reads better?".length + 1,
            "Which layout reads better?".length + 2,
          ],
        },
        {
          name: "zoom-1.5",
          variant: "attachment-inline-caret",
          width: WIDTH,
          scale: 1.5,
          offsets: [2, AFTER_CHIP - 1, AFTER_CHIP, IN_WORDS],
        },
      ]) {
        const context = await browser.newContext({
          viewport: { width: scene.width, height: 760 },
          colorScheme: "dark",
          deviceScaleFactor: 2,
        });
        const page = await context.newPage();
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: scene.variant, width: scene.width, frame: "component", scale: scene.scale })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          await page.waitForSelector(".acpmux-md [data-inline-attachment] img");
          await page.addStyleTag({ content: ".acpmux-md { caret-color: rgb(255, 0, 255) !important; }" });
          await page.locator(".acpmux-md").focus();
          const { band, chipHeight, lineHeight } = await layout(page);
          expect(chipHeight).toBeGreaterThan(lineHeight * 1.5);
          for (const offset of scene.offsets) {
            await caretAt(page, offset);
            const caret = await caretRows(page, band);
            const height = caret.bottom - caret.top;
            report.push(
              `${engine} ${scene.name} offset ${offset}: caret ${height.toFixed(2)}px, line ${lineHeight.toFixed(2)}px`,
            );
            if (Math.abs(height - lineHeight) > TOLERANCE)
              failures.push(
                `${engine} ${scene.name} offset ${offset}: caret ${height.toFixed(2)}px, line ${lineHeight.toFixed(2)}px`,
              );
          }
          if (process.env.CMUX_HOVER_CAPTURE_DIR)
            await page.screenshot({
              path: path.join(process.env.CMUX_HOVER_CAPTURE_DIR, `caret-${engine}-${scene.name}.png`),
              caret: "initial",
            });
        } finally {
          await context.close();
        }
      }
    } finally {
      console.log(report.join("\n"));
      await browser.close();
      await vite.close();
    }
    expect(failures).toEqual([]);
  };

  test("chromium: the caret beside a pasted image is the text's height", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test("webkit: the caret beside a pasted image is the text's height", () =>
    run("webkit", () => webkit.launch({ headless: true })));
});
