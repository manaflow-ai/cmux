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

  /// The chip's picture, the words after it on its line, and the paragraph's line height.
  const layout = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-md [data-inline-attachment]")!;
      const face = node.querySelector<HTMLElement>(".acpmux-attachment") ?? node;
      const chip = face.getBoundingClientRect();
      const paragraph = node.closest("p")!;
      const text = node.nextSibling!;
      const range = document.createRange();
      range.setStart(text, 1);
      range.setEnd(text, 4);
      const words = range.getBoundingClientRect();
      return {
        chip: { left: chip.left, right: chip.right, top: chip.top, bottom: chip.bottom },
        words: { left: words.left, right: words.right, top: words.top, bottom: words.bottom },
        // In viewport px: under a zoom (Agent Chat Zoom) the computed value is the unzoomed one.
        lineHeight:
          (parseFloat(getComputedStyle(paragraph).lineHeight) * paragraph.getBoundingClientRect().width) /
          paragraph.offsetWidth,
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
      for (const [name, size] of Object.entries({ default: {}, "zoom-1.5": { scale: 1.5 } } as Record<
        string,
        Record<string, string | number>
      >)) {
        const context = await browser.newContext({
          viewport: { width: WIDTH, height: 760 },
          colorScheme: "dark",
          deviceScaleFactor: 2,
        });
        const page = await context.newPage();
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "attachment-inline-caret", width: WIDTH, frame: "component", ...size })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
            timeout: 90_000,
          });
          await page.waitForSelector(".acpmux-md [data-inline-attachment] img");
          await page.addStyleTag({ content: ".acpmux-md { caret-color: rgb(255, 0, 255) !important; }" });
          await page.locator(".acpmux-md").focus();
          const { chip, words, lineHeight } = await layout(page);
          // The chip is taller than the text: the line's box is the chip's.
          expect(chip.bottom - chip.top).toBeGreaterThan(lineHeight * 1.5);
          const band = { top: Math.min(chip.top, words.top) - 8, bottom: Math.max(chip.bottom, words.bottom) + 8 };
          const places = {
            "beside the chip": {
              offset: AFTER_CHIP,
              left: chip.right - 2,
              right: Math.max(words.left, chip.right) + 12,
            },
            "inside the words": { offset: IN_WORDS, left: words.left + 2, right: words.right + 6 },
          };
          for (const [where, { offset, left, right }] of Object.entries(places)) {
            await caretAt(page, offset);
            const caret = await caretRows(page, { ...band, left, right });
            const height = caret.bottom - caret.top;
            const middle = (caret.top + caret.bottom) / 2;
            report.push(
              `${engine} ${name} ${where}: caret ${height.toFixed(2)}px (${caret.top.toFixed(2)}..${caret.bottom.toFixed(2)}), line ${lineHeight}px, words ${words.top.toFixed(2)}..${words.bottom.toFixed(2)}, chip ${chip.top.toFixed(2)}..${chip.bottom.toFixed(2)}`,
            );
            if (height > lineHeight + TOLERANCE)
              failures.push(
                `${engine} ${name}: the caret ${where} is ${height.toFixed(2)}px tall, the text's line ${lineHeight}px`,
              );
            if (middle < words.top || middle > words.bottom)
              failures.push(
                `${engine} ${name}: the caret ${where} is not on the words' line (middle ${middle.toFixed(2)})`,
              );
          }
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
