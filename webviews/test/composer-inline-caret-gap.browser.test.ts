// The caret beside an attachment in the prompt's text keeps clear of the chip's edge (Leo,
// 2026-11-07: "the blinking caret to the right of attachments needs a little more space than what
// we have right now ... it just sort of bleeds into the glass of the attachment"). Measured on the
// painted caret: the prompt's caret is drawn magenta and found in a screenshot, in both of the lane's
// engines (WebKit is the app's), at both densities and the interface sizes. The prompt's text is the
// same as before: the room is the chip's own, never a typed space.
// cmux-web-test-timeout: 600
import { expect, setDefaultTimeout, test } from "bun:test";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-inline-caret-gap.browser.test.ts", async () => {
  setDefaultTimeout(600_000);

  const ENTRY = "agent-pane.composer";
  const CARET = { r: 255, g: 0, b: 255 };
  /// The sizes the composer is drawn at: the default, compact density, and the interface sizes.
  /// The pane's width: the composer is Chat Text Width's 800px column (conversation.css --cv-column),
  /// so at Agent Chat Zoom 1.5 in a 1400px pane WebKit's composer fits the first chip beside the text
  /// and wraps the second, and the pair no longer sits on one line. At 1280px every size keeps both
  /// chips on the line after the text, in Chromium and WebKit alike.
  const WIDTH = 1280;
  const SIZES: Record<string, Record<string, string | number>> = {
    default: {},
    compact: { density: "compact" },
    "interface-0.9": { interfaceScale: 0.9 },
    "interface-1.25": { interfaceScale: 1.25 },
    "zoom-1.5": { scale: 1.5 },
  };
  /// How far, in CSS px, the caret after a chip may stand from the chip-to-chip gap: the caret after
  /// a chip stands as far from it as the next chip would (Leo's ask; before the fix it stood on the
  /// chip's edge in Chromium and 2px off it in WebKit, against a 4px gap).
  const TOLERANCE = 1;

  /// How far the painted caret is from the point `gap` px after a chip's right edge `edge`: 0 when its
  /// column covers that point. Each engine paints its 1px caret on whole pixels, Chromium's just
  /// before the insertion point and WebKit's just after it, so the column, not one of its edges, is
  /// where the caret is.
  const offGap = (caret: { left: number; right: number }, edge: number, gap: number) =>
    Math.max(0, caret.left - (edge + gap), edge + gap - caret.right);

  /// The chip's visible box: the strip's tile inside an inline node, else the node's chip.
  const chipBoxes = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-md [data-inline-attachment]")].map((node) => {
        const face =
          node.querySelector<HTMLElement>(".acpmux-attachment") ??
          node.querySelector<HTMLElement>(".acpmux-md-inline-chip")!;
        const box = face.getBoundingClientRect();
        return { left: box.left, right: box.right, top: box.top, bottom: box.bottom };
      }),
    );

  /// A few painted frames later: the caret blinks, so a screenshot that missed it tries again then.
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

  /// The painted caret's columns (CSS px) inside `band`, read from screenshots until a blink shows it
  /// at the same place twice in a row.
  async function caretColumns(page: Page, band: { left: number; right: number; top: number; bottom: number }) {
    const scale = await page.evaluate(() => window.devicePixelRatio);
    const clip = {
      x: band.left,
      y: band.top,
      width: band.right - band.left,
      height: band.bottom - band.top,
    };
    let last: { left: number; right: number } | undefined;
    for (let attempt = 0; attempt < 60; attempt++) {
      const shot = PNG.sync.read(await page.screenshot({ clip, caret: "initial", scale: "device" }));
      const columns = new Set<number>();
      for (let at = 0; at < shot.data.length; at += 4) {
        const [r, g, b] = [shot.data[at]!, shot.data[at + 1]!, shot.data[at + 2]!];
        if (Math.abs(r - CARET.r) < 40 && g < 60 && Math.abs(b - CARET.b) < 40) columns.add((at / 4) % shot.width);
      }
      if (columns.size) {
        const xs = [...columns];
        const seen = { left: band.left + Math.min(...xs) / scale, right: band.left + (Math.max(...xs) + 1) / scale };
        if (last && last.left === seen.left && last.right === seen.right) return seen;
        last = seen;
      }
      await nextFrames(page);
    }
    throw new Error(last ? `the caret never held still (last at ${last.left})` : "the caret never showed");
  }

  async function open(page: Page, port: number, variant: string, size: Record<string, string | number>) {
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant, width: WIDTH, frame: "component", ...size })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    await page.addStyleTag({ content: ".acpmux-md { caret-color: rgb(255, 0, 255) !important; }" });
    await page.locator(".acpmux-md").focus();
  }

  /// Puts the caret `offset` positions into the first paragraph (an attachment is one position).
  /// It goes to the start first, a frame before: headless WebKit's caret does not blink, so a caret
  /// set where it already is keeps the place it was painted at, before the chips' pictures loaded.
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
  };

  /// The prompt without its attachments' tokens (attachments.ts inlineToken): the typed text alone.
  const withoutTokens = (prompt: { value: string }) => prompt.value.replace(/\uFFFC[^\uFFFC]*\uFFFC/g, "");

  /// With CMUX_CARET_GAP_CAPTURE_DIR, the chip's right edge and the caret, at four times.
  async function capture(page: Page, name: string, chip: { right: number; top: number; bottom: number }) {
    const dir = process.env.CMUX_CARET_GAP_CAPTURE_DIR;
    if (!dir) return;
    await mkdir(dir, { recursive: true });
    const clip = {
      x: chip.right - 40,
      y: chip.top - 8,
      width: 64,
      height: chip.bottom - chip.top + 16,
    };
    for (let attempt = 0; attempt < 40; attempt++) {
      const shot = await page.screenshot({ clip, caret: "initial", scale: "device" });
      const png = PNG.sync.read(shot);
      if (
        png.data.some(
          (_, at) => at % 4 === 0 && png.data[at]! > 215 && png.data[at + 1]! < 60 && png.data[at + 2]! > 215,
        )
      ) {
        await writeFile(path.join(dir, `${name}.png`), shot);
        return;
      }
      await nextFrames(page);
    }
  }

  const value = (page: Page) =>
    page.evaluate(() => {
      const field = document.querySelector(".acpmux-md-field") as HTMLElement & {
        acpmuxMarkdownField?: { value(): string };
      };
      return { value: field.acpmuxMarkdownField!.value() };
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
      for (const [name, size] of Object.entries(SIZES)) {
        const context = await browser.newContext({
          viewport: { width: WIDTH, height: 760 },
          colorScheme: "dark",
          deviceScaleFactor: 4,
        });
        const page = await context.newPage();
        try {
          // Two screenshots at the end of the text, side by side: the caret after the last one, then
          // between the two.
          await open(page, port, "attachment-inline-reorder", size);
          await page.waitForFunction(
            () => document.querySelectorAll(".acpmux-md [data-inline-attachment] img").length === 2,
          );
          const before = await value(page);
          const text = "Which layout reads better?".length;
          await caretAt(page, text + 2);
          const [first, second] = await chipBoxes(page);
          expect(Math.abs(first!.top - second!.top)).toBeLessThan(1);
          const chipGap = second!.left - first!.right;
          const band = { top: second!.top, bottom: second!.bottom };
          const beyond = { ...band, left: second!.left + 8, right: second!.right + 40 };
          const after = await caretColumns(page, beyond);
          await capture(page, `${engine}-${name}-after-chip`, second!);
          await caretAt(page, text + 1);
          const between = await caretColumns(page, {
            ...band,
            left: first!.left,
            right: second!.right,
          });
          // The caret after a chip, the last one or the first of two, stands one chip gap from it. (The
          // caret before a chip meets its leading edge, where it stays off the glass.)
          const clear = {
            "after the last chip": offGap(after, second!.right, chipGap),
            "after the first of two chips": offGap(between, first!.right, chipGap),
          };
          report.push(`${engine} ${name} chip gap ${chipGap.toFixed(2)}, caret off it ${JSON.stringify(clear)}`);
          for (const [where, off] of Object.entries(clear))
            if (off > TOLERANCE)
              failures.push(
                `${engine} ${name}: the caret ${where} is ${off.toFixed(2)}px off the ${chipGap.toFixed(2)}px chip gap`,
              );
          // A click just right of the last chip puts the caret after it, never selects the chip.
          await page.mouse.click(second!.right + 2, (second!.top + second!.bottom) / 2);
          const clicked = await caretColumns(page, beyond);
          if (clicked.left < second!.right)
            failures.push(`${engine} ${name}: a click right of the chip put the caret at ${clicked.left}`);
          // The room is the chip's own: the prompt is the text and the two attachments, nothing more.
          expect(await value(page)).toEqual(before);
          expect(withoutTokens(before)).toBe("Which layout reads better?");

          // A huge paste's text card at the end of the prompt: the same room after it as between chips.
          // Under the 1.5 zoom the card has a line of its own at the end of the field, where the caret
          // goes down to the next line.
          const cardGap = chipGap;
          if (size.scale) continue;
          await open(page, port, "text-pasted-inline", size);
          const sent = await value(page);
          await caretAt(page, "Why does the build fail? ".length + 1);
          const [card] = await chipBoxes(page);
          const tail = await caretColumns(page, { ...card!, right: card!.right + 40 });
          await capture(page, `${engine}-${name}-after-card`, card!);
          const off = offGap(tail, card!.right, cardGap);
          report.push(`${engine} ${name} text card: caret off the chip gap ${off.toFixed(2)}`);
          if (off > TOLERANCE)
            failures.push(`${engine} ${name}: the caret after the text card is ${off.toFixed(2)}px off the chip gap`);
          // Selected, the card wears the chip's ring: its rules reach it through its right-click
          // menu's wrapper (markdownField.css). The node's class is the selection ProseMirror marks;
          // arrows never select a chip (composer-inline-arrows.browser.test.ts).
          const ring = await page.evaluate(() => {
            const node = document.querySelector<HTMLElement>(".acpmux-md .acpmux-md-inline");
            const chip = node?.querySelector<HTMLElement>(".acpmux-md-inline-chip");
            if (!node || !chip) return "no text card";
            node.classList.add("ProseMirror-selectednode");
            const style = getComputedStyle(chip).outlineStyle;
            node.classList.remove("ProseMirror-selectednode");
            return style;
          });
          if (ring !== "solid") failures.push(`${engine} ${name}: the selected text card's ring is ${ring}`);
          expect(await value(page)).toEqual(sent);
          // The paste's own space after the card stays the only one.
          expect(withoutTokens(sent)).toBe("Why does the build fail?  ");
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

  test("chromium: the caret keeps clear of a chip's edge", () =>
    run("chromium", () => chromium.launch({ headless: true })));
  test("webkit: the caret keeps clear of a chip's edge", () => run("webkit", () => webkit.launch({ headless: true })));
});
