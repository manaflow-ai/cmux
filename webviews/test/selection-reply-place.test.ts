// cmux-web-test-timeout: 900
// Where the selection's Reply chip goes (conversation/SelectionReply.tsx). Leo, 2026-11-11, on a
// selection that ended partway into a list item's line, its chip at the far end of the next line:
// "this reply is in the wrong spot, actually. Like if there's line— if there's space near the line.
// I don't know what happened here, because if you go close, you still get it. But if you go deep
// into it, there's something that messes up there."
//
// Every shown chip is on the selection's last line, next to its last character: its left edge
// within 12 px after that character, or (where that runs past the column) flipped so its right edge
// is that character's; never on another line. It stays inside its bounds (the transcript column;
// the pane where the column is narrower than the chip) and the visible transcript, and hides when
// the selection's last line scrolls out of it.
//
// It renders the gallery's agent-pane.selection-reply stages in Chromium and WebKit (the app's
// engine); each stage's play makes the selection. CI fails the file when an engine cannot launch
// (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/selection-reply-place.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("selection-reply-place.test.ts", async () => {
  setDefaultTimeout(600_000);
  const ENTRY = "agent-pane.selection-reply";
  const engines: [string, BrowserType][] = [];
  if (await probeEngineOrSkip("selection-reply-place chromium", "chromium", chromium))
    engines.push(["chromium", chromium]);
  if (await probeEngineOrSkip("selection-reply-place webkit", "webkit", webkit)) engines.push(["webkit", webkit]);
  if (engines.length === 0) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (variant: string, width: number) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width, theme: "Catppuccin Mocha" })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, [ENTRY], { browser: browsers.get(engines[0]![0]) });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  /** What the page shows for the current selection: the chip's box (none when it hides), the
   *  selection's last character's box (measured here, character by character), the chip's bounds
   *  and the visible transcript. */
  type Read = {
    shown: boolean;
    chip: Box;
    line: Box;
    bounds: Box;
    view: { top: number; bottom: number };
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
      /** The selection's last character with ink and a box, and its text node. */
      const lastCharacter = (range: Range) => {
        const nodes: Text[] = [];
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode() as Text | null; node; node = walker.nextNode() as Text | null)
          if (range.intersectsNode(node) && !node.parentElement!.closest(".cv-selection-reply")) nodes.push(node);
        const one = document.createRange();
        for (const node of nodes.reverse()) {
          const from = node === range.startContainer ? range.startOffset : 0;
          const to = node === range.endContainer ? range.endOffset : node.length;
          for (let at = to - 1; at >= from; at -= 1) {
            if (/\s/.test(node.data[at]!)) continue;
            one.setStart(node, at);
            one.setEnd(node, at + 1);
            const rect = Array.from(one.getClientRects())
              .filter((r) => r.width > 0 && r.height > 0)
              .pop();
            if (rect) return { rect, node };
          }
        }
        throw new Error("the selection has no character with a box");
      };
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
          const last = lastCharacter(range);
          const endElement = last.node.parentElement!;
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
          return {
            shown: shown(chipElement),
            chip,
            line: box(last.rect),
            bounds,
            view: { top: scroller.top, bottom: foot },
          };
        },
      });
    });

  const open = async (engine: string, variant: string, width: number, height = 700): Promise<Page> => {
    const page: Page = await browsers.get(engine)!.newPage({ viewport: { width, height } });
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
  const placed = async (engine: string, variant: string, width: number): Promise<Read> => {
    const page = await open(engine, variant, width);
    const result = await read(page);
    await page.close();
    return result;
  };

  const centre = (box: Box) => (box.top + box.bottom) / 2;
  /** Every shown chip: in its bounds, in the visible transcript, and on the selection's last line
   *  (its centre inside that character's line box), never on the line before or after it. */
  const placedWell = ({ shown, chip, line, bounds, view }: Read) => {
    expect(shown, "the chip shows").toBe(true);
    expect(chip.right, "the chip stays in its bounds").toBeLessThanOrEqual(bounds.right + 0.5);
    expect(chip.left, "the chip stays in its bounds").toBeGreaterThanOrEqual(bounds.left - 0.5);
    expect(chip.top, "the chip stays in the visible transcript").toBeGreaterThanOrEqual(view.top - 0.5);
    expect(chip.bottom, "the chip stays in the visible transcript").toBeLessThanOrEqual(view.bottom + 0.5);
    expect(centre(chip), "on the selection's last line, not the next").toBeLessThanOrEqual(line.bottom);
    expect(centre(chip), "on the selection's last line, not the one before").toBeGreaterThanOrEqual(line.top);
  };
  /** Just after the selection's last character: its left edge within 12 px after it, on its line. */
  const after = (result: Read) => {
    placedWell(result);
    const { chip, line } = result;
    expect(chip.left, "after the last character").toBeGreaterThanOrEqual(line.right - 0.5);
    expect(chip.left - line.right, "within 12 px of the last character").toBeLessThanOrEqual(12);
    expect(Math.abs(centre(chip) - centre(line)), "centred on the last character's line").toBeLessThanOrEqual(1);
  };
  /** Next to the last character: after it, or flipped over the selection's own words where after
   *  would run past the bounds. */
  const nextToEnd = (result: Read) => {
    const { chip, line, bounds } = result;
    if (line.right + 6 + (chip.right - chip.left) <= bounds.right + 0.5) return after(result);
    placedWell(result);
    expect(Math.abs(chip.right - line.right), "flipped: its right edge at the last character's").toBeLessThanOrEqual(1);
  };

  for (const [engine] of engines) {
    describe(engine, () => {
      // His case at the widths the pane opens at: the end is mid-line, so after it always fits.
      for (const width of [1040, 760])
        test(`Leo's case: a selection ending partway into a list item's line (${width} px)`, async () => {
          after(await placed(engine, "chip-list-item", width));
        });
      test("Leo's case at 400 px: next to the last character", async () => {
        nextToEnd(await placed(engine, "chip-list-item", 400));
      });
      test("the same words dragged backward (right to left)", async () => {
        after(await placed(engine, "chip-list-item-backward", 1040));
      });
      for (const [variant, what] of [
        ["chip-mid-line", "two words mid-line, text all around"],
        ["chip-above", "a phrase mid-line with a clear line over it"],
        ["chip-multi-line", "three lines ending mid-line"],
        ["chip-paragraph-end", "a selection ending its paragraph (at its line's end)"],
        ["chip-inline-code", "a selection ending inside inline code at the paragraph's end"],
        ["chip-code-mid", "a selection ending inside inline code mid-line"],
        ["chip-link-mid", "a selection ending inside a link"],
        ["chip-bold-inline", "a selection ending inside bold words"],
        ["chip-bold-mid", "a selection across a bold word"],
        ["chip-short-mid", "two short words in a dense reply"],
        ["chip-backward-multi-line", "three lines dragged backward"],
        ["chip-under-sent-line", "a reply under a Sent to line"],
      ] as const)
        test(`${what}: just after its last character`, async () => {
          after(await placed(engine, variant, 1040));
          nextToEnd(await placed(engine, variant, 400));
        });

      // The space at a wrap: the range's end is on the next line, the chip stays on the last
      // character's line (that line is full, so the chip flips over the selection's own words).
      test("a selection taking the space at a line's wrap: on its last character's line, never the next", async () => {
        for (const width of [1040, 400]) nextToEnd(await placed(engine, "chip-wrap-end", width));
      });

      for (const width of [1040, 400])
        test(`a selection ending at a line's right edge: flipped over its own last words (${width} px)`, async () => {
          const result = await placed(engine, "chip-right-edge", width);
          expect(result.line.right, "the selection ends near the column's edge").toBeGreaterThan(
            result.bounds.right - 80,
          );
          nextToEnd(result);
        });

      test("a short Markdown prompt narrower than the chip (400 px): the chip stays in the pane", async () => {
        const result = await placed(engine, "chip-short-prompt", 400);
        nextToEnd(result);
        expect(result.chip.right, "inside the pane").toBeLessThanOrEqual(400);
      });

      test("a selection scrolled out of view hides the chip; scrolled back, it shows again", async () => {
        const page = await open(engine, "chip-short-mid", 1040, 300);
        try {
          // The selection's last line in the middle of the visible transcript first.
          const start = await read(page);
          await scroll(
            page,
            Math.round((start.line.top + start.line.bottom) / 2 - (start.view.top + start.view.bottom) / 2),
          );
          const before = await read(page);
          nextToEnd(before);
          const by = before.line.bottom - before.view.top + 30;
          await scroll(page, by);
          const away = await read(page);
          expect(away.line.bottom, "the selection's last line is above the visible transcript").toBeLessThan(
            away.view.top,
          );
          expect(away.shown, "the chip hides").toBe(false);
          await scroll(page, -by);
          nextToEnd(await read(page));
        } finally {
          await page.close();
        }
      });

      // Seeded random selections (either direction) and scroll offsets over the stages: every result
      // either hides, or is in the visible transcript, in its bounds and on the selection's last line
      // next to its last character (after, flipped, or under where neither fits).
      const STAGES = ["chip-list-item", "chip-short-mid", "chip-right-edge", "chip-bold-mid", "chip-short-prompt"];
      for (const width of [1040, 400])
        test(`invariant over seeded random selections and scrolls (${width} px)`, async () => {
          const failures: string[] = [];
          let shownCount = 0;
          for (const [index, variant] of STAGES.entries()) {
            const page = await open(engine, variant, width, 420);
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
                  scroller.scrollTop = Math.floor(
                    random() * Math.max(0, scroller.scrollHeight - scroller.clientHeight),
                  );
                  const from = Math.floor(random() * nodes.length);
                  const to = Math.min(nodes.length - 1, from + Math.floor(random() * 3));
                  const a = nodes[from]!;
                  const b = nodes[to]!;
                  const start = Math.floor(random() * a.length);
                  const end =
                    to === from
                      ? Math.min(a.length, start + 1 + Math.floor(random() * 60))
                      : 1 + Math.floor(random() * (b.length - 1));
                  if (random() < 0.5) document.getSelection()!.setBaseAndExtent(a, start, b, Math.max(1, end));
                  else document.getSelection()!.setBaseAndExtent(b, Math.max(1, end), a, start);
                  scroller.dispatchEvent(new Event("scroll"));
                  document.dispatchEvent(new PointerEvent("pointerup", { bubbles: true }));
                  return document.getSelection()!.toString().slice(0, 40);
                }, seed);
                await settle(page);
                const result = await read(page);
                if (!result.shown) continue;
                shownCount += 1;
                const problems: string[] = [];
                const { chip, line, bounds, view } = result;
                const chipWidth = chip.right - chip.left;
                if (chip.left < bounds.left - 0.5 || chip.right > bounds.right + 0.5) problems.push("out of bounds");
                if (chip.top < view.top - 0.5 || chip.bottom > view.bottom + 0.5)
                  problems.push("out of the visible transcript");
                const onLine = centre(chip) >= line.top && centre(chip) <= line.bottom;
                const afterEnd = onLine && chip.left >= line.right - 0.5 && chip.left - line.right <= 12;
                const flipped = onLine && Math.abs(chip.right - line.right) <= 1;
                const under = chip.top >= line.bottom && chip.top - line.bottom <= 7;
                const fitsAfter = line.right + 6 + chipWidth <= bounds.right + 0.5;
                if (fitsAfter ? !afterEnd : !(flipped || under)) problems.push("not next to the last character");
                if (problems.length)
                  failures.push(
                    `${variant} seed ${seed} "${picked}": ${problems.join(", ")} (chip ${JSON.stringify(chip)}, last ${JSON.stringify(line)})`,
                  );
              }
            } finally {
              await page.close();
            }
          }
          expect(shownCount, "most selections show the chip").toBeGreaterThan(30);
          expect(failures, `${failures.length} of ${STAGES.length * 30}`).toEqual([]);
        });
    });
  }
});
