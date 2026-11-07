// cmux-web-test-timeout: 300
// Where the selection's Reply chip goes (conversation/SelectionReply.tsx). Leo, 2026-11-07, on the
// chip floating off to the side of a selection: "if it's ever on the right edge, just make it in
// line ... Sometimes it gets a bit strange, I guess. Like at the sides, because it's not aligned."
//
// The chip sits on the selection's last line, just after its last character and centred on that
// line; when the column has no room there it wraps under the selection's end. It never goes past the
// transcript column's right edge into the margin. A selection whose spot over its end is clear keeps
// the chip there, where it always was.
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
  type Placed = { chip: Box; line: Box; column: Box };

  /** Opens a stage (its play makes the selection and waits for the chip) and reads the chip's box,
   *  the selection's last character's box (its last line) and the transcript column's box. */
  const placed = async (variant: string, width: number): Promise<Placed> => {
    const page: Page = await browser!.newPage({ viewport: { width, height: 700 } });
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
    const read = await page.evaluate(() => {
      const box = (rect: DOMRect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
      const range = document.getSelection()!.getRangeAt(0);
      const end = range.endContainer as Text;
      const last = document.createRange();
      last.setStart(end, range.endOffset - 1);
      last.setEnd(end, range.endOffset);
      return {
        chip: box(document.querySelector(".cv-selection-reply")!.getBoundingClientRect()),
        line: box(last.getBoundingClientRect()),
        column: box(end.parentElement!.closest(".cv-md")!.getBoundingClientRect()),
      };
    });
    await page.close();
    return read;
  };

  const centre = (box: Box) => (box.top + box.bottom) / 2;
  /** On the last line just after its last character, centred on it; or wrapped under that line. */
  const inlineOrWrapped = ({ chip, line, column }: Placed) => {
    expect(chip.right, "the chip stays in the column").toBeLessThanOrEqual(column.right + 0.5);
    expect(chip.left, "the chip stays in the column").toBeGreaterThanOrEqual(column.left - 0.5);
    if (chip.left >= line.right - 0.5) {
      expect(Math.abs(centre(chip) - centre(line)), "inline: centred on the selection's last line").toBeLessThanOrEqual(
        1,
      );
      expect(chip.left - line.right, "inline: just after the last character").toBeLessThanOrEqual(12);
    } else {
      expect(chip.top, "wrapped: under the selection's last line").toBeGreaterThan(line.bottom);
      expect(chip.top - line.bottom, "wrapped: on the next line, not further down").toBeLessThanOrEqual(12);
    }
  };

  for (const width of [1040, 400])
    test(`a selection ending at a line's right edge wraps the chip under it, never into the margin (${width} px)`, async () => {
      const read = await placed("chip-right-edge", width);
      inlineOrWrapped(read);
      expect(read.line.right, "the selection ends near the column's edge").toBeGreaterThan(read.column.right - 80);
      expect(read.chip.top, "no room on the line: the chip wraps").toBeGreaterThan(read.line.bottom);
    });

  test("a multi-line selection puts the chip on its last line", async () => {
    inlineOrWrapped(await placed("chip-multi-line", 1040));
  });

  test("a selection ending inside inline code puts the chip on that line, centred", async () => {
    inlineOrWrapped(await placed("chip-inline-code", 1040));
  });

  test("a selection with a clear spot over its end keeps the chip there, as before", async () => {
    const { chip, line } = await placed("chip-above", 1040);
    const width = chip.right - chip.left;
    const height = chip.bottom - chip.top;
    expect(Math.abs(chip.left - (line.right - width / 2)), "centred over the end").toBeLessThanOrEqual(0.5);
    expect(Math.abs(chip.top - (line.top - height - 6)), "6 px over the line").toBeLessThanOrEqual(0.5);
  });
});
