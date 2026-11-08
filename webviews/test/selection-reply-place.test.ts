// cmux-web-test-timeout: 600
// Where the selection's Reply chip goes (conversation/SelectionReply.tsx). Leo, 2026-11-07, on the
// chip floating off to the side of a selection: "if it's ever on the right edge, just make it in
// line ... Sometimes it gets a bit strange, I guess. Like at the sides, because it's not aligned."
//
// Every shown chip is inside the visible transcript (its scroller above the composer), inside its
// bounds (the transcript column; the pane where the column is narrower than the chip) and over no
// unselected character; where no spot is all three, the chip hides. A selection whose spot over its
// end is clear keeps the chip there, where it always was; one that ends its line sits the chip just
// after its last character, centred on that line.
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
  setDefaultTimeout(480_000);
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
  /** What the page shows for the current selection: the chip's box (none when it hides), the
   *  selection's last character's box, the chip's bounds, the visible transcript and the unselected
   *  characters the chip covers (more than 1 px each way). */
  type Read = {
    shown: boolean;
    chip: Box;
    line: Box;
    bounds: Box;
    view: { top: number; bottom: number };
    covered: string;
  };

  /** Installs `window.readReply()` (Read) and `window.settled()` (resolves once the chip is placed
   *  or hidden for the current selection). */
  const install = (page: Page) =>
    page.evaluate(() => {
      const box = (rect: DOMRect) => ({ left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom });
      const BLOCK = "p, li, h1, h2, h3, h4, h5, h6, td, th, dd, dt, figcaption, blockquote, .cv-md, [data-row-id]";
      // raf-read: the reads are layout boxes (getBoundingClientRect forces layout), not painted
      // pixels; the frames only let React commit the chip's placement (a layout effect, before paint).
      const frame = () => new Promise((done) => requestAnimationFrame(done));
      const chipOf = () => document.querySelector<HTMLElement>(".cv-selection-reply");
      const shown = (chip: HTMLElement | null) =>
        !!chip && chip.style.visibility !== "hidden" && chip.dataset.hidden !== "true";
      Object.assign(window, {
        settled: async () => {
          await frame();
          await frame();
          for (let at = 0; at < 10; at += 1) {
            const chip = chipOf();
            if (!chip || shown(chip) || chip.dataset.hidden === "true") return;
            await frame();
          }
        },
        readReply: () => {
          const range = document.getSelection()!.getRangeAt(0);
          const chipElement = chipOf();
          const chip = chipElement
            ? box(chipElement.getBoundingClientRect())
            : { left: 0, top: 0, right: 0, bottom: 0 };
          const end = range.endContainer;
          const endElement = end.nodeType === 1 ? (end as Element) : end.parentElement!;
          const wide = Array.from(range.getClientRects()).filter((rect) => rect.width > 0);
          const line = wide.length ? box(wide[wide.length - 1]!) : box(range.getBoundingClientRect());
          const block = endElement.closest(BLOCK)!.getBoundingClientRect();
          const body = endElement.closest(".cv-md, [data-row-id]")!.getBoundingClientRect();
          let bounds = { left: block.left, top: 0, right: body.right, bottom: innerHeight };
          if (bounds.right - bounds.left < chip.right - chip.left)
            bounds = { left: 0, top: 0, right: innerWidth, bottom: innerHeight };
          const scroller = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
          const dock = document.querySelector(".acpmux-dock");
          const foot = Math.min(
            scroller.bottom,
            ...(dock ? [dock, ...Array.from(dock.children)] : [])
              .map((element) => element.getBoundingClientRect())
              .filter((rect) => rect.height && rect.top > scroller.top && rect.bottom >= scroller.bottom - 1)
              .map((rect) => rect.top),
          );
          let covered = "";
          if (shown(chipElement)) {
            const one = document.createRange();
            const cross = (rect: DOMRect | Box, by: number) =>
              Math.min(rect.right, chip.right) - Math.max(rect.left, chip.left) > by &&
              Math.min(rect.bottom, chip.bottom) - Math.max(rect.top, chip.top) > by;
            for (const row of Array.from(document.querySelectorAll("[data-row-id]"))) {
              if (!cross(row.getBoundingClientRect(), 0)) continue;
              const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
              for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null) {
                one.selectNodeContents(node);
                if (!Array.from(one.getClientRects()).some((rect) => cross(rect, 1))) continue;
                for (let at = 0; at < node.data.length; at += 1) {
                  if (/\s/.test(node.data[at]!)) continue;
                  if (range.comparePoint(node, at) === 0 && range.comparePoint(node, at + 1) === 0) continue;
                  one.setStart(node, at);
                  one.setEnd(node, at + 1);
                  if (cross(one.getBoundingClientRect(), 1)) covered += node.data[at];
                }
              }
            }
          }
          return { shown: shown(chipElement), chip, line, bounds, view: { top: scroller.top, bottom: foot }, covered };
        },
      });
    });

  const open = async (variant: string, width: number, height = 700): Promise<Page> => {
    const page: Page = await browser!.newPage({ viewport: { width, height } });
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
    // Placed, or hidden where the stage's selection is out of a short viewport's view.
    await page.waitForFunction(() => {
      const chip = document.querySelector<HTMLElement>(".cv-selection-reply");
      return chip && (chip.style.visibility !== "hidden" || chip.dataset.hidden === "true");
    });
    await install(page);
    return page;
  };
  const read = (page: Page) => page.evaluate(() => (window as unknown as { readReply: () => Read }).readReply());
  const settle = (page: Page) => page.evaluate(() => (window as unknown as { settled: () => Promise<void> }).settled());
  /** Scrolls the transcript by `by` px, as a wheel would. */
  const scroll = async (page: Page, by: number) => {
    await page.evaluate((by) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop += by;
      scroller.dispatchEvent(new Event("scroll"));
    }, by);
    await settle(page);
  };
  const placed = async (variant: string, width: number): Promise<Read> => {
    const page = await open(variant, width);
    const result = await read(page);
    await page.close();
    return result;
  };

  const centre = (box: Box) => (box.top + box.bottom) / 2;
  /** What holds for every shown chip: in its bounds, in the visible transcript, over no unselected text. */
  const placedWell = ({ shown, chip, bounds, view, covered }: Read) => {
    expect(shown, "the chip shows").toBe(true);
    expect(chip.right, "the chip stays in its bounds").toBeLessThanOrEqual(bounds.right + 0.5);
    expect(chip.left, "the chip stays in its bounds").toBeGreaterThanOrEqual(bounds.left - 0.5);
    expect(chip.top, "the chip stays in the visible transcript").toBeGreaterThanOrEqual(view.top - 0.5);
    expect(chip.bottom, "the chip stays in the visible transcript").toBeLessThanOrEqual(view.bottom + 0.5);
    expect(covered, "the chip covers no unselected text").toBe("");
  };
  /** Just after the selection's last character, centred on its line. */
  const inline = ({ chip, line }: Read) => {
    expect(chip.left, "inline: after the last character").toBeGreaterThanOrEqual(line.right);
    expect(chip.left - line.right, "inline: just after the last character").toBeLessThanOrEqual(12);
    expect(Math.abs(centre(chip) - centre(line)), "inline: centred on the selection's last line").toBeLessThanOrEqual(
      1,
    );
  };

  for (const width of [1040, 400])
    test(`a selection ending at a line's right edge mid-paragraph: no margin, no unselected word covered (${width} px)`, async () => {
      const result = await placed("chip-right-edge", width);
      expect(result.line.right, "the selection ends near the column's edge").toBeGreaterThan(result.bounds.right - 80);
      placedWell(result);
    });

  test("a multi-line selection ending mid-line: the chip covers no unselected word", async () => {
    placedWell(await placed("chip-multi-line", 1040));
  });

  test("a mid-line selection whose spot over its end holds text: the chip covers no unselected word", async () => {
    placedWell(await placed("chip-mid-line", 1040));
  });

  test("a selection ending inside inline code at its paragraph's end: next to the end, over it or inline", async () => {
    const result = await placed("chip-inline-code", 1040);
    placedWell(result);
    const { chip, line } = result;
    const width = chip.right - chip.left;
    // Over the end and centred on it (the line before is short), else inline after it.
    if (chip.bottom <= line.top) expect(Math.abs(chip.left - (line.right - width / 2))).toBeLessThanOrEqual(0.5);
    else inline(result);
  });

  test("a selection ending its paragraph: inline, centred on that line", async () => {
    const result = await placed("chip-paragraph-end", 1040);
    placedWell(result);
    inline(result);
  });

  test("two short words mid-paragraph in a dense reply: every spot measured where it is", async () => {
    placedWell(await placed("chip-short-mid", 1040));
  });

  for (const width of [1040, 400])
    test(`a selection across a bold word (overlapping boxes): no unselected text covered (${width} px)`, async () => {
      placedWell(await placed("chip-bold-mid", width));
    });

  test("a backward multi-line drag: no unselected text covered near either end", async () => {
    placedWell(await placed("chip-backward-multi-line", 1040));
  });

  // Review on #37507 (698288c9): a short right-aligned prompt has a column narrower than the chip,
  // and the chip ran past the pane.
  test("a short Markdown prompt narrower than the chip (400 px): the chip stays in the pane", async () => {
    const result = await placed("chip-short-prompt", 400);
    placedWell(result);
    expect(result.chip.right, "inside the pane").toBeLessThanOrEqual(400);
  });

  // Review on #37507 (698288c9): a selection scrolled out of the visible transcript put the chip at
  // the edge, over other text.
  test("a selection scrolled out of view hides the chip; scrolled back, it shows again", async () => {
    const page = await open("chip-short-mid", 1040, 300);
    try {
      // The selection's last line in the middle of the visible transcript first.
      const start = await read(page);
      await scroll(
        page,
        Math.round((start.line.top + start.line.bottom) / 2 - (start.view.top + start.view.bottom) / 2),
      );
      const before = await read(page);
      placedWell(before);
      const by = before.line.bottom - before.view.top + 30;
      await scroll(page, by);
      const away = await read(page);
      expect(away.line.bottom, "the selection's last line is above the visible transcript").toBeLessThan(away.view.top);
      expect(away.shown, "the chip hides").toBe(false);
      await scroll(page, -by);
      placedWell(await read(page));
    } finally {
      await page.close();
    }
  });

  // Seeded random selections and scroll offsets over the stages: every result either hides, or is
  // in the visible transcript, in its bounds and over no unselected character.
  const STAGES = ["chip-short-mid", "chip-right-edge", "chip-bold-mid", "chip-inline-code", "chip-short-prompt"];
  for (const width of [1040, 400])
    test(`invariant over seeded random selections and scrolls (${width} px)`, async () => {
      const failures: string[] = [];
      let shownCount = 0;
      for (const [index, variant] of STAGES.entries()) {
        const page = await open(variant, width, 420);
        try {
          for (let round = 0; round < 30; round += 1) {
            const seed = (width * 1000 + index * 100 + round) >>> 0;
            const picked = await page.evaluate((seed) => {
              let state = seed;
              const random = () => {
                state = (state + 0x6d2b79f5) >>> 0;
                let t = state;
                t = Math.imul(t ^ (t >>> 15), t | 1);
                t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
                return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
              };
              const nodes: Text[] = [];
              for (const row of Array.from(document.querySelectorAll('[data-row-id^="gallery-reply-"]'))) {
                const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
                for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null)
                  if (node.data.trim() && !node.parentElement!.closest("pre, .cv-codeblock")) nodes.push(node);
              }
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              scroller.scrollTop = Math.floor(random() * Math.max(0, scroller.scrollHeight - scroller.clientHeight));
              const from = Math.floor(random() * nodes.length);
              const to = Math.min(nodes.length - 1, from + Math.floor(random() * 3));
              const a = nodes[from]!;
              const b = nodes[to]!;
              const start = Math.floor(random() * a.length);
              const end =
                to === from
                  ? Math.min(a.length, start + 1 + Math.floor(random() * 60))
                  : 1 + Math.floor(random() * (b.length - 1));
              document.getSelection()!.setBaseAndExtent(a, start, b, Math.max(1, end));
              scroller.dispatchEvent(new Event("scroll"));
              document.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
              return document.getSelection()!.toString().slice(0, 40);
            }, seed);
            await settle(page);
            const result = await read(page);
            if (!result.shown) continue;
            shownCount += 1;
            const problems: string[] = [];
            const { chip, bounds, view, covered } = result;
            if (chip.left < bounds.left - 0.5 || chip.right > bounds.right + 0.5) problems.push("out of bounds");
            if (chip.top < view.top - 0.5 || chip.bottom > view.bottom + 0.5)
              problems.push("out of the visible transcript");
            if (covered) problems.push(`covers "${covered}"`);
            if (problems.length)
              failures.push(
                `${variant} seed ${seed} "${picked}": ${problems.join(", ")} (chip ${JSON.stringify(chip)})`,
              );
          }
        } finally {
          await page.close();
        }
      }
      expect(shownCount, "most selections show the chip").toBeGreaterThan(30);
      expect(failures, `${failures.length} of ${STAGES.length * 30}`).toEqual([]);
    });

  test("a selection with a clear spot over its end keeps the chip there, as before", async () => {
    const { chip, line } = await placed("chip-above", 1040);
    const width = chip.right - chip.left;
    const height = chip.bottom - chip.top;
    expect(Math.abs(chip.left - (line.right - width / 2)), "centred over the end").toBeLessThanOrEqual(0.5);
    expect(Math.abs(chip.top - (line.top - height - 6)), "6 px over the line").toBeLessThanOrEqual(0.5);
  });
});
