// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture paths and selectors, not shipped UI.
// A tool-call block whose lines run past its right edge shows that it scrolls sideways (Leo
// 2026-10-21, ask-d900f5acf9, an "Edited codex-excursions.md" diff and Shell blocks: "this doesn't
// really display properly or even show that there's a horizontal scrollbar i think it's cut off").
// Unwrapped, an edit's diff (Pierre's code rows, in a shadow root) and a command's output keep a
// thin thumb on no track under their lines at rest, in the shared thumb color (scrollers.ts
// SIDEWAYS_ATTRIBUTE), on a lane no taller than the thin scroller's. A block cut to its eight-line
// preview ends with that lane, clear of the preview's bottom fade. Nothing over a block shows a
// resize cursor (the same ask: "the cursor hover that turns into the resizing cursor").
//
// The lane never moves the transcript and is never an empty tail (Codex review of #23967): a diff
// and a call output keep it inside their own bottom gap, so they are as tall with the scrollbar as
// without it; a running command keeps it while it runs, so a streamed line that starts or stops
// running past the edge does not move what is under it; a settled block whose lines fit, and any
// wrapped one, has none.
//
// Under the scrollbar fade (Lawrence 2026-10-23, msg 11494: "auto-fades away, and grows bigger on
// near-hover so it's easier to grab"; the agent pane's default, `data-cmux-scroller-fade` on
// <html>), the same thumb fades like every other scroller: none at rest, shown while the lines
// scroll sideways, and thicker while the pointer is near the block's bottom edge. Without the fade
// (Debug Settings agentPane.debug.scrollerFade off) it stays at rest, as above.
//
// Before: the diff's thumb was transparent until the rows scrolled, the output had the engine's
// own scroller (an overlay that shows only while it scrolls, or a 15px classic bar), and a cut
// diff's lane lay past the preview's cut. Nothing at rest said the lines went on but the fade.
//
// Real Chromium (scrollbars on: headless hides them by default) and WebKit (the app's engine) on
// the transcript gallery's long-line states; CI fails the file when it cannot launch them.
// Locally: CMUX_BROWSER_TESTS=1 and the file name, with the repo's test runner.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { PNG } from "pngjs";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-block-sideways-scrollbar.test.ts", async () => {
  setDefaultTimeout(240_000);
  const ENTRY = "agent-pane.transcript";
  const launchers: [string, () => Promise<Browser>][] = [
    ["chromium", () => chromium.launch({ headless: true, ignoreDefaultArgs: ["--hide-scrollbars"] })],
    ["webkit", () => webkit.launch({ headless: true })],
  ];
  /// The thin scroller's tallest lane; WebKit's and Chromium's classic bars are 15 px.
  const THIN = 10;
  /// The cards' corner radius (12px) and a little more: the lane's right end a reading skips.
  const CORNER = 16;

  /// A gallery state, its block, the box in it that scrolls sideways and its Wrap lines button.
  type Block = { variant: string; card: string; scroller: string; wrap: string; shadow: boolean; cut: boolean };
  const diff = (variant: string, cut: boolean): Block => ({
    variant,
    card: ".cv-edit-diff",
    scroller: ".cv-edit-diff__body",
    wrap: ".cv-edit-diff__wrap",
    shadow: true,
    cut,
  });
  const shell = (variant: string, cut: boolean): Block => ({
    variant,
    card: ".cv-shell",
    scroller: ".cv-shell__body",
    wrap: '.cv-shell__actions button[aria-label="Wrap lines"]',
    shadow: false,
    cut,
  });
  const call = (variant: string, cut: boolean): Block => ({
    variant,
    card: ".cv-tool-output-card",
    scroller: ".cv-tool-output",
    wrap: '.cv-tool-output__actions button[aria-label="Wrap lines"]',
    shadow: false,
    cut,
  });
  const output = call("output-unwrapped-long-line", false);
  /// A call output past eight lines, cut to its preview (Codex review of #23967, round 4).
  const outputCut = call("output-unwrapped-long-cut", true);
  /// Unwrapped, every line past the edge, settled.
  const blocks: Block[] = [
    diff("edit-long-line-code", false),
    diff("edit-long-line-code-cut", true),
    shell("shell-unwrapped-long-line", false),
    shell("shell-unwrapped-long-cut", true),
    output,
    outputCut,
  ];
  /// Blocks whose height holds while their lines start and stop running past the edge: a diff and
  /// a call output always, a command while it runs.
  const steady: Block[] = [
    diff("edit-long-line-code", false),
    diff("edit-long-line-code-cut", true),
    shell("shell-live-unwrapped-long-line", false),
    shell("shell-live-unwrapped-long-cut", true),
    output,
    outputCut,
  ];
  /// Settled blocks whose lines, once they fit, leave no lane: as tall as wrapped.
  const settled: Block[] = [
    shell("shell-unwrapped-long-line", false),
    shell("shell-unwrapped-long-cut", true),
    output,
    outputCut,
  ];
  /// Cut call outputs: eight whole lines and the lane under them.
  const cutCalls: Block[] = [outputCut];
  /// Wrapped diffs, cut and whole.
  const wrapped: Block[] = [diff("edit-long-line-prose", true), diff("edit-preview-open", false)];

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: null },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, launch] of launchers) browsers.set(name, await launch());
    // One load compiles the entry's modules for every state of it.
    await warmGalleryFrame(vite, ENTRY, { browser: browsers.get("chromium"), params: { variant: blocks[0]!.variant } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /// The state played and drawn: its block open, Pierre's rows painted, and the block in view.
  async function open(engine: string, block: Block): Promise<Page> {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 760, height: 720 } });
    await installPaintedFrames(page);
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: block.variant })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 120_000 });
    expect(await page.evaluate(() => document.documentElement.dataset.galleryReady)).toBe("1");
    await page.waitForFunction(
      ({ scroller, shadow }) => {
        const body = document.querySelector(scroller);
        if (!body) return false;
        return shadow
          ? [...body.querySelectorAll("*")].some((element) => element.shadowRoot?.querySelector("[data-line]"))
          : Boolean(body.querySelector(".cv-line"));
      },
      block,
      { timeout: 60_000 },
    );
    await page.evaluate((card) => document.querySelector(card)!.scrollIntoView({ block: "center" }), block.card);
    // The pointer away from every block, and long enough past the last scroll that no scroller
    // shows because it is scrolling (SCROLLING_HIDE_MS).
    await page.mouse.move(2, 2);
    await page.evaluate(async () => {
      for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
    });
    // fixed-wait: what is measured is the scroller at rest, after the scrolling mark has gone.
    await page.waitForTimeout(1200);
    return page;
  }

  /// The box that scrolls sideways (Pierre's `[data-code]` for a diff), its lane, and whether its
  /// lines run past it.
  const measure = (page: Page, block: Block) =>
    page.evaluate(({ scroller, shadow }) => {
      const body = document.querySelector<HTMLElement>(scroller)!;
      const inner = shadow
        ? [...body.querySelectorAll("*")]
            .map((element) => element.shadowRoot?.querySelector<HTMLElement>("[data-code]"))
            .find(Boolean)
        : body;
      const box = inner!;
      const rect = box.getBoundingClientRect();
      const outer = body.getBoundingClientRect();
      const style = getComputedStyle(box);
      return {
        overflow: box.scrollWidth - box.clientWidth,
        lane: Math.round(
          box.offsetHeight - box.clientHeight - parseFloat(style.borderTopWidth) - parseFloat(style.borderBottomWidth),
        ),
        left: rect.left,
        width: rect.width,
        bottom: rect.bottom - parseFloat(style.borderBottomWidth),
        // The block's own bottom: a cut preview hides what lies past it.
        shownBottom: outer.bottom,
      };
    }, block);

  /// Whether the lane draws a thumb at rest, read from the pixels the page drew. Scrolled to the
  /// start, a thumb sits at the lane's left end and the lane's right part shows the card under it
  /// (a track with no color, the right-edge fade over the lines). `CORNER` px at each end are left
  /// out: a card whose lane is its bottom edge clips them to its rounded corners, the page's color.
  /// A column that differs from the last one read in some row is drawn on. A thumb is a run of such
  /// columns; a track would be all of them.
  async function thumb(page: Page, box: Awaited<ReturnType<typeof measure>>) {
    if (box.lane <= 0) return { thumb: false, track: false, columns: 0, width: 0 };
    const clip = {
      x: Math.ceil(box.left),
      y: Math.round(box.bottom - box.lane),
      width: Math.floor(box.width) - 1,
      height: box.lane,
    };
    const png = PNG.sync.read(await page.screenshot({ clip }));
    const end = png.width - CORNER;
    const reference = end - 1;
    let columns = 0;
    for (let x = CORNER; x < end; x++)
      for (let y = 0; y < png.height; y++) {
        const at = (y * png.width + x) * 4;
        const ref = (y * png.width + reference) * 4;
        const delta =
          Math.abs(png.data[at]! - png.data[ref]!) +
          Math.abs(png.data[at + 1]! - png.data[ref + 1]!) +
          Math.abs(png.data[at + 2]! - png.data[ref + 2]!);
        if (delta > 24) {
          columns++;
          break;
        }
      }
    return { thumb: columns >= 16, track: columns > end - CORNER - 8, columns, width: end - CORNER };
  }

  /// The fade's blocks: a diff (Pierre's rows in a shadow root) and a command's output (the page's
  /// own box), both whole.
  const fading: Block[] = [diff("edit-long-line-code", false), shell("shell-unwrapped-long-line", false)];

  /// How many rows of the lane's left part have thumb ink: the thumb's thickness. The lane's right
  /// end (past `CORNER`) is the reference, as in `thumb`.
  async function thickness(page: Page, box: Awaited<ReturnType<typeof measure>>) {
    if (box.lane <= 0) return 0;
    const clip = {
      x: Math.ceil(box.left),
      y: Math.round(box.bottom - box.lane),
      width: Math.floor(box.width) - 1,
      height: box.lane,
    };
    const png = PNG.sync.read(await page.screenshot({ clip }));
    const reference = png.width - CORNER - 1;
    let rows = 0;
    for (let y = 0; y < png.height; y++)
      for (let x = CORNER; x < CORNER + 24 && x < reference; x++) {
        const at = (y * png.width + x) * 4;
        const ref = (y * png.width + reference) * 4;
        const delta =
          Math.abs(png.data[at]! - png.data[ref]!) +
          Math.abs(png.data[at + 1]! - png.data[ref + 1]!) +
          Math.abs(png.data[at + 2]! - png.data[ref + 2]!);
        if (delta > 24) {
          rows++;
          break;
        }
      }
    return rows;
  }

  /// Waits until the block's sideways box has (`on`) or lacks `attribute`.
  const boxMark = (page: Page, block: Block, attribute: string, on: boolean) =>
    page.waitForFunction(
      ({ scroller, shadow, attribute, on }) => {
        const body = document.querySelector(scroller)!;
        const box = shadow
          ? [...body.querySelectorAll("*")]
              .map((element) => element.shadowRoot?.querySelector("[data-code]"))
              .find(Boolean)
          : body;
        return box?.hasAttribute(attribute) === on;
      },
      { ...block, attribute, on },
      { timeout: 10_000 },
    );

  const painted = (page: Page) =>
    page.evaluate(async () => {
      for (let left = 2; left > 0; left--) await window.cmuxPaintFrame();
    });

  /// The block's heights, its sideways box's lane and mark, and the gap above its first line and
  /// under its last (rows: Pierre's `[data-line]`, or the body's `.cv-line`).
  const look = (page: Page, block: Block) =>
    page.evaluate(({ scroller, card, shadow }) => {
      const body = document.querySelector<HTMLElement>(scroller)!;
      const box = shadow
        ? [...body.querySelectorAll("*")]
            .map((element) => element.shadowRoot?.querySelector<HTMLElement>("[data-code]"))
            .find(Boolean)!
        : body;
      const rows = [...box.querySelectorAll(shadow ? "[data-line]" : ".cv-line")];
      const rect = box.getBoundingClientRect();
      const style = getComputedStyle(body);
      return {
        sideways: box.hasAttribute("data-cmux-sideways"),
        wrap: body.closest("[data-wrap]")?.getAttribute("data-wrap"),
        body: Math.round(body.getBoundingClientRect().height),
        card: Math.round(document.querySelector(card)!.getBoundingClientRect().height),
        lane: box.offsetHeight - box.clientHeight,
        inset: Math.round(rows[0]!.getBoundingClientRect().top - rect.top),
        tail: Math.round(rect.bottom - rows.at(-1)!.getBoundingClientRect().bottom),
        maxHeight: style.maxHeight,
        lineHeight: style.getPropertyValue("--cmux-diff-line-height"),
      };
    }, block);

  /// Makes the block's lines run past its edge again (`past`) or all fit, as streamed text would,
  /// and waits for its sideways box's mark to follow: a command's or output's lines shortened, or a
  /// diff's body widened past its rows.
  async function runPast(page: Page, block: Block, past: boolean) {
    await page.evaluate(
      ({ scroller, shadow, past }) => {
        const body = document.querySelector<HTMLElement>(scroller)!;
        if (shadow) body.style.width = past ? "" : "8000px";
        else
          for (const line of body.querySelectorAll<HTMLElement>(".cv-line")) {
            line.dataset.long ??= line.textContent ?? "";
            line.textContent = past ? line.dataset.long : "ok";
          }
      },
      { ...block, past },
    );
    await page.waitForFunction(
      ({ scroller, shadow, past }) => {
        const body = document.querySelector(scroller)!;
        const box = shadow
          ? [...body.querySelectorAll("*")]
              .map((element) => element.shadowRoot?.querySelector("[data-code]"))
              .find(Boolean)
          : body;
        return box?.hasAttribute("data-cmux-sideways") === past;
      },
      { ...block, past },
      { timeout: 10_000 },
    );
    await painted(page);
  }

  /// Every point of a grid over `selector`'s visible part whose element (inside shadow roots too)
  /// shows a resize cursor or can be resized.
  const resizeCursors = (page: Page, selector: string) =>
    page.evaluate((selector) => {
      const found: string[] = [];
      for (const target of document.querySelectorAll(selector)) {
        const rect = target.getBoundingClientRect();
        const top = Math.max(rect.top, 0);
        const bottom = Math.min(rect.bottom, innerHeight);
        for (let row = 0; row <= 8; row++)
          for (let column = 0; column <= 16; column++) {
            const x = rect.left + 1 + ((rect.width - 2) * column) / 16;
            const y = top + 1 + ((bottom - top - 2) * row) / 8;
            let hit = document.elementFromPoint(x, y);
            for (let depth = 0; hit?.shadowRoot && depth < 8; depth++) {
              const inner = hit.shadowRoot.elementFromPoint(x, y);
              if (!inner || inner === hit) break;
              hit = inner;
            }
            if (!hit) continue;
            const style = getComputedStyle(hit);
            if (/resize/.test(style.cursor) || (style.resize && style.resize !== "none"))
              found.push(
                `${hit.tagName.toLowerCase()}.${hit.className} at ${Math.round(x)},${Math.round(y)}: cursor ${style.cursor}, resize ${style.resize}`,
              );
          }
      }
      return found;
    }, selector);

  for (const [engine] of launchers)
    describe(engine, () => {
      for (const block of blocks)
        test(`${block.variant}: a thin thumb on no track at rest under lines that run past the edge, no resize cursor`, async () => {
          const page = await open(engine, block);
          try {
            const box = await measure(page, block);
            expect(box.overflow).toBeGreaterThan(100);
            // The lane is there and thin.
            expect({ lane: box.lane, thin: box.lane > 0 && box.lane <= THIN }).toEqual({ lane: box.lane, thin: true });
            // It is in view: a cut preview ends with it.
            expect(box.bottom).toBeLessThanOrEqual(box.shownBottom + 0.5);
            const drawn = await thumb(page, box);
            console.log(`${engine} ${block.variant}: ${JSON.stringify({ ...box, ...drawn })}`);
            expect({ thumb: drawn.thumb, track: drawn.track }).toEqual({ thumb: true, track: false });
            expect(await resizeCursors(page, `${block.card}, .acpmux-edited-toggle, .cv-tool`)).toEqual([]);
          } finally {
            await page.close();
          }
        });

      for (const block of fading)
        test(`${block.variant}: under the scrollbar fade, no thumb at rest, one while it scrolls, thicker near its bar`, async () => {
          const page = await open(engine, block);
          try {
            await page.evaluate(() => document.documentElement.setAttribute("data-cmux-scroller-fade", ""));
            await painted(page);
            const box = await measure(page, block);
            const rest = await thumb(page, box);
            // A sideways wheel over the lines, clear of the bar.
            await page.mouse.move(box.left + box.width / 2, box.bottom - box.lane - 24);
            await page.mouse.wheel(40, 0);
            await boxMark(page, block, "data-cmux-scrolling", true);
            await painted(page);
            const scrolling = await thumb(page, await measure(page, block));
            const thin = await thickness(page, await measure(page, block));
            await boxMark(page, block, "data-cmux-scrolling", false);
            await painted(page);
            const rested = await thumb(page, await measure(page, block));
            // The pointer comes down to the bar.
            await page.mouse.move(box.left + box.width / 2, box.bottom - 3, { steps: 4 });
            await boxMark(page, block, "data-cmux-scroller-near", true);
            await painted(page);
            const near = await thumb(page, await measure(page, block));
            const wide = await thickness(page, await measure(page, block));
            console.log(
              `${engine} ${block.variant} fade: ${JSON.stringify({ rest, scrolling, rested, near, thin, wide })}`,
            );
            expect({
              rest: rest.thumb,
              scrolling: scrolling.thumb,
              rested: rested.thumb,
              near: near.thumb,
              thicker: wide > thin,
            }).toEqual({ rest: false, scrolling: true, rested: false, near: true, thicker: true });
          } finally {
            await page.close();
          }
        });

      // A block's height holds while its lines start or stop running past the edge (Codex review
      // of #23967): the transcript under a streaming block never jumps by the scrollbar's lane.
      for (const block of steady)
        test(`${block.variant}: as tall while its lines start and stop running past the edge`, async () => {
          const page = await open(engine, block);
          try {
            const before = await look(page, block);
            expect(before.sideways).toBe(true);
            await runPast(page, block, false);
            const fits = await look(page, block);
            await runPast(page, block, true);
            const again = await look(page, block);
            console.log(`${engine} ${block.variant} steady: ${JSON.stringify({ before, fits, again })}`);
            const height = ({ body, card }: typeof before) => ({ body, card });
            expect([height(fits), height(again)]).toEqual([height(before), height(before)]);
          } finally {
            await page.close();
          }
        });

      // Settled, lines that fit leave no lane: the block is as tall unwrapped as wrapped, and a
      // whole one ends as far under its last line as its first line starts under its top.
      for (const block of settled)
        test(`${block.variant}: settled, lines that fit leave no empty lane`, async () => {
          const page = await open(engine, block);
          try {
            await runPast(page, block, false);
            const unwrapped = await look(page, block);
            await page.click(block.wrap);
            await page.waitForFunction(
              (scroller) => document.querySelector(scroller)?.getAttribute("data-wrap") === "true",
              block.scroller,
            );
            await painted(page);
            const shown = await look(page, block);
            console.log(`${engine} ${block.variant} settled: ${JSON.stringify({ unwrapped, shown })}`);
            expect({ body: unwrapped.body, card: unwrapped.card }).toEqual({ body: shown.body, card: shown.card });
            if (!block.cut) expect([unwrapped.tail, shown.tail]).toEqual([unwrapped.inset, shown.inset]);
          } finally {
            await page.close();
          }
        });

      // A cut call output shows its eight lines and the lane under them, whether or not its lines
      // run past the edge (Codex review of #23967, round 4): the lane is added to the preview's
      // cut, not taken out of it, so the bar never covers an eighth line.
      for (const block of cutCalls)
        test(`${block.variant}: a cut preview shows eight whole lines and the lane under them`, async () => {
          const page = await open(engine, block);
          try {
            const inside = () =>
              page.evaluate((scroller) => {
                const box = document.querySelector<HTMLElement>(scroller)!;
                const style = getComputedStyle(box);
                return {
                  preview: box.getAttribute("data-preview"),
                  sideways: box.hasAttribute("data-cmux-sideways"),
                  shown: box.clientHeight - parseFloat(style.paddingTop) - parseFloat(style.paddingBottom),
                  eight: 8 * parseFloat(style.lineHeight),
                  lane: box.offsetHeight - box.clientHeight + parseFloat(style.paddingBottom),
                };
              }, block.scroller);
            const past = await inside();
            await runPast(page, block, false);
            const fits = await inside();
            console.log(`${engine} ${block.variant} cut: ${JSON.stringify({ past, fits })}`);
            expect(past.sideways).toBe(true);
            expect(fits.sideways).toBe(false);
            for (const shown of [past, fits]) {
              expect(shown.preview).toBe("cut");
              expect(shown.shown).toBeCloseTo(shown.eight, 0);
              expect(shown.lane).toBeGreaterThan(0);
            }
          } finally {
            await page.close();
          }
        });

      // Wrapped rows never scroll sideways: Pierre's box keeps no lane, and a cut preview is eight rows.
      for (const block of wrapped)
        test(`${block.variant}: a wrapped diff keeps no lane`, async () => {
          const page = await open(engine, block);
          try {
            const shown = await look(page, block);
            console.log(`${engine} ${block.variant} wrapped: ${JSON.stringify(shown)}`);
            expect({ wrap: shown.wrap, lane: shown.lane }).toEqual({ wrap: "true", lane: 0 });
            if (block.cut) expect(shown.maxHeight).toBe(`${8 * (parseFloat(shown.lineHeight) || 18)}px`);
            else expect(shown.tail).toBe(shown.inset);
          } finally {
            await page.close();
          }
        });
    });
});
