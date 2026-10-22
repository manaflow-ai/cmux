// cmux-web-test-timeout: 300
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

  /// A gallery state, its block and the box in it that scrolls sideways.
  type Block = { variant: string; card: string; scroller: string; shadow: boolean; cut: boolean };
  const blocks: Block[] = [
    {
      variant: "edit-long-line-code",
      card: ".cv-edit-diff",
      scroller: ".cv-edit-diff__body",
      shadow: true,
      cut: false,
    },
    {
      variant: "edit-long-line-code-cut",
      card: ".cv-edit-diff",
      scroller: ".cv-edit-diff__body",
      shadow: true,
      cut: true,
    },
    { variant: "shell-unwrapped-long-line", card: ".cv-shell", scroller: ".cv-shell__body", shadow: false, cut: false },
    { variant: "shell-unwrapped-long-cut", card: ".cv-shell", scroller: ".cv-shell__body", shadow: false, cut: true },
  ];

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
    for (const block of blocks)
      await warmGalleryFrame(vite, ENTRY, { browser: browsers.get("chromium"), params: { variant: block.variant } });
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

  /// Whether the lane draws a thumb at rest: the columns of the lane whose pixels change when every
  /// scrollbar thumb on the page (and in Pierre's shadow roots) is made transparent.
  async function thumb(page: Page, box: Awaited<ReturnType<typeof measure>>) {
    if (box.lane <= 0) return { thumb: false, track: false, columns: 0 };
    const clip = {
      x: Math.ceil(box.left),
      y: Math.round(box.bottom - box.lane),
      width: Math.floor(box.width),
      height: box.lane,
    };
    const shot = async () => PNG.sync.read(await page.screenshot({ clip }));
    const drawn = await shot();
    await page.evaluate(() => {
      const rule =
        "::-webkit-scrollbar-thumb { background: transparent !important; border-color: transparent !important; }";
      const hide = (root: Document | ShadowRoot) => {
        const style = document.createElement("style");
        style.textContent = rule;
        (root instanceof Document ? root.head : root).append(style);
      };
      hide(document);
      for (const element of document.querySelectorAll("*")) if (element.shadowRoot) hide(element.shadowRoot);
    });
    await page.evaluate(async () => {
      for (let left = 3; left > 0; left--) await window.cmuxPaintFrame();
    });
    const bare = await shot();
    let columns = 0;
    for (let x = 0; x < drawn.width; x++)
      for (let y = 0; y < drawn.height; y++) {
        const at = (y * drawn.width + x) * 4;
        const delta =
          Math.abs(drawn.data[at]! - bare.data[at]!) +
          Math.abs(drawn.data[at + 1]! - bare.data[at + 1]!) +
          Math.abs(drawn.data[at + 2]! - bare.data[at + 2]!);
        if (delta > 24) {
          columns++;
          break;
        }
      }
    // A thumb: a run of columns; on no track: not the lane's whole width.
    return { thumb: columns >= 16, track: columns > drawn.width - 8, columns };
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
            expect({ ...drawn, columns: 0 }).toEqual({ thumb: true, track: false, columns: 0 });
            expect(await resizeCursors(page, `${block.card}, .acpmux-edited-toggle, .cv-tool`)).toEqual([]);
          } finally {
            await page.close();
          }
        });
    });
});
