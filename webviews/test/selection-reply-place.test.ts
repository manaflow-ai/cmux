// cmux-web-test-timeout: 300
// Where the selection's Reply chip goes (conversation/SelectionReply.tsx). Leo, 2026-11-07, on the
// chip floating off to the side of a selection: "if it's ever on the right edge, just make it in
// line ... Sometimes it gets a bit strange, I guess. Like at the sides, because it's not aligned."
//
// The chip never covers unselected text, never leaves the viewport and never goes past the
// transcript column into the margin. A selection whose spot over its end is clear keeps the chip
// there, where it always was; one that ends its line sits the chip just after its last character,
// centred on that line.
//
// It renders the gallery's agent-pane.selection-reply stages in Chromium; each stage's play makes
// the selection. CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/selection-reply-place.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("selection-reply-place.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.selection-reply";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("selection reply place", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [ENTRY], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  type Placed = {
    chip: Box;
    line: Box;
    column: Box;
    /** The visible transcript: its scroller's box above the composer dock (viewport px). */
    view: { top: number; bottom: number };
    /** Unselected characters the chip covers (more than 1 px each way), anywhere in the transcript. */
    covered: string;
  };

  /** Opens a stage (its play makes the selection and waits for the chip), scrolls the page so the
   *  selection's last line is the first or last one in view when `edge` says, and reads the chip's
   *  box, the selection's last character's box (its last line), the column's box and what
   *  unselected text the chip covers. */
  const placed = async (
    variant: string,
    width: number,
    edge?: "top" | "bottom",
  ): Promise<Placed> => {
    const page: Page = await browser!.newPage({ viewport: { width, height: edge ? 240 : 700 } });
    for (;;) {
      await page.goto(stageURL(variant, width));
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 120_000,
        });
        break;
      } catch (error) {
        // The first load can run Vite's dependency optimizer and reload mid-compile.
        if (!/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
    await page.waitForFunction(() => {
      const chip = document.querySelector<HTMLElement>(".cv-selection-reply");
      return chip && chip.style.visibility !== "hidden";
    });
    if (edge) {
      const off = await page.evaluate((edge) => {
        const range = document.getSelection()!.getRangeAt(0);
        const rects = Array.from(range.getClientRects()).filter((rect) => rect.width > 0);
        const last = () => rects[rects.length - 1]!;
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const shown = scroller.getBoundingClientRect();
        const dock = document.querySelector(".acpmux-dock");
        const foot = Math.min(
          shown.bottom,
          ...(dock ? [dock, ...Array.from(dock.children)] : [])
            .map((element) => element.getBoundingClientRect())
            .filter((box) => box.height && box.top > shown.top && box.bottom >= shown.bottom - 1)
            .map((box) => box.top),
        );
        // The line wholly in view, 6 px from the edge, the line past it out of view.
        scroller.scrollTop += edge === "top" ? last().top - shown.top - 6 : last().bottom - foot + 6;
        scroller.dispatchEvent(new Event("scroll"));
        const now = Array.from(range.getClientRects()).filter((rect) => rect.width > 0);
        const line = now[now.length - 1]!;
        return edge === "top" ? line.top - shown.top : foot - line.bottom;
      }, edge);
      expect(Math.abs(off - 6), "the selection's last line is at the transcript's edge").toBeLessThanOrEqual(3);
      // The chip follows a scroll on the next render.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    }
    const read = await page.evaluate(() => {
      const box = (rect: DOMRect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
      const range = document.getSelection()!.getRangeAt(0);
      const end = range.endContainer as Text;
      const last = document.createRange();
      last.setStart(end, range.endOffset - 1);
      last.setEnd(end, range.endOffset);
      const chip = document.querySelector(".cv-selection-reply")!.getBoundingClientRect();
      let covered = "";
      const one = document.createRange();
      for (const row of Array.from(document.querySelectorAll("[data-row-id]"))) {
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null)
          for (let at = 0; at < node.data.length; at += 1) {
            if (/\s/.test(node.data[at]!)) continue;
            if (range.comparePoint(node, at) === 0 && range.comparePoint(node, at + 1) === 0) continue;
            one.setStart(node, at);
            one.setEnd(node, at + 1);
            const rect = one.getBoundingClientRect();
            const across = Math.min(rect.right, chip.right) - Math.max(rect.left, chip.left);
            const down = Math.min(rect.bottom, chip.bottom) - Math.max(rect.top, chip.top);
            if (across > 1 && down > 1) covered += node.data[at];
          }
      }
      return {
        chip: box(chip),
        line: box(last.getBoundingClientRect()),
        column: box(end.parentElement!.closest(".cv-md")!.getBoundingClientRect()),
        view: (() => {
          const shown = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          const dock = document.querySelector(".acpmux-dock");
          const foot = Math.min(
            shown.bottom,
            ...(dock ? [dock, ...Array.from(dock.children)] : [])
              .map((element) => element.getBoundingClientRect())
              .filter((box) => box.height && box.top > shown.top && box.bottom >= shown.bottom - 1)
              .map((box) => box.top),
          );
          return { top: shown.top, bottom: foot };
        })(),
        covered,
      };
    });
    await page.close();
    return read;
  };

  const centre = (box: Box) => (box.top + box.bottom) / 2;
  /** What holds for every chip: in the column, in the viewport, over no unselected text. */
  const placedWell = ({ chip, column, view, covered }: Placed) => {
    expect(chip.right, "the chip stays in the column").toBeLessThanOrEqual(column.right + 0.5);
    expect(chip.left, "the chip stays in the column").toBeGreaterThanOrEqual(column.left - 0.5);
    expect(chip.top, "the chip stays in the visible transcript").toBeGreaterThanOrEqual(view.top);
    expect(chip.bottom, "the chip stays in the visible transcript").toBeLessThanOrEqual(view.bottom);
    expect(covered, "the chip covers no unselected text").toBe("");
  };
  /** Just after the selection's last character, centred on its line. */
  const inline = ({ chip, line }: Placed) => {
    expect(chip.left, "inline: after the last character").toBeGreaterThanOrEqual(line.right);
    expect(chip.left - line.right, "inline: just after the last character").toBeLessThanOrEqual(12);
    expect(Math.abs(centre(chip) - centre(line)), "inline: centred on the selection's last line").toBeLessThanOrEqual(1);
  };

  for (const width of [1040, 400])
    test(`a selection ending at a line's right edge mid-paragraph: no margin, no unselected word covered (${width} px)`, async () => {
      const read = await placed("chip-right-edge", width);
      expect(read.line.right, "the selection ends near the column's edge").toBeGreaterThan(read.column.right - 80);
      placedWell(read);
    });

  test("a multi-line selection ending mid-line: the chip covers no unselected word", async () => {
    placedWell(await placed("chip-multi-line", 1040));
  });

  test("a mid-line selection whose spot over its end holds text: the chip covers no unselected word", async () => {
    placedWell(await placed("chip-mid-line", 1040));
  });

  test("a selection ending inside inline code at its paragraph's end: next to the end, over it or inline", async () => {
    const read = await placed("chip-inline-code", 1040);
    placedWell(read);
    const { chip, line } = read;
    const width = chip.right - chip.left;
    // Over the end and centred on it (the line before is short), else inline after it.
    if (chip.bottom <= line.top) expect(Math.abs(chip.left - (line.right - width / 2))).toBeLessThanOrEqual(0.5);
    else inline(read);
  });

  test("a selection ending its paragraph: inline, centred on that line", async () => {
    const read = await placed("chip-paragraph-end", 1040);
    placedWell(read);
    inline(read);
  });

  for (const edge of ["top", "bottom"] as const)
    test(`a selection on the ${edge === "top" ? "first" : "last"} line in view: the chip stays wholly in the viewport`, async () => {
      placedWell(await placed("chip-paragraph-end", 1040, edge));
    });

  test("a selection with a clear spot over its end keeps the chip there, as before", async () => {
    const { chip, line } = await placed("chip-above", 1040);
    const width = chip.right - chip.left;
    const height = chip.bottom - chip.top;
    expect(Math.abs(chip.left - (line.right - width / 2)), "centred over the end").toBeLessThanOrEqual(0.5);
    expect(Math.abs(chip.top - (line.top - height - 6)), "6 px over the line").toBeLessThanOrEqual(0.5);
  });
});
