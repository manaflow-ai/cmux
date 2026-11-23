// cmux-web-test-timeout: 600
// The composer's +, mic and Send stay on the draft's last line as it grows, and its thumb shows only
// for a moment. Leo, 2026-11-23: "buttons need to be at the bottom" and "move the thumb inside, and it
// should only appear briefly when the length changes, or when you scroll. not all the time. never all
// the time." design/composer-bottom-controls.md.
//
// 1. At 1, 3 and 8 lines and past the cap (scrolled to the end inside the box), at 400 and 1100 px,
//    each control's centre is the last visible line's centre.
// 2. The draft's scroller carries no scrolling mark at rest, and its thumb's ink is 0%. A line added
//    past the cap marks it for a moment, and so does a wheel scroll; each mark is gone soon after.
//
// Chromium on the gallery stage (agent-pane.composer-bottom-controls), drafts typed with Shift-Return.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { COMPOSER_MD_FIELD, PLUS_PICKER } from "../src/agent-session/acpmux/composerSelectors";
import { MINIMAL_SCROLLER_ATTRIBUTE, SCROLLING_ATTRIBUTE } from "../src/scrollers";

await requireBrowserLane("composer-bottom-controls.browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-bottom-controls: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer bottom controls", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.composer-bottom-controls";
  const VARIANT = "lines-1";
  /** Subpixel rounding plus the glyph's half-pixel snap. */
  const TOLERANCE = 1.5;
  /** Past the cap: the draft scrolls inside the box. */
  const PAST_CAP = 40;
  /** Longer than the thumb's show-and-fade (scrollers.ts). */
  const REST_MS = 2_500;

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (width: number): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 720 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  /** Replaces the draft with `lines` lines, typed with Shift-Return, the caret at its end. */
  const typeLines = async (page: Page, lines: number) => {
    await page.locator(`${COMPOSER_MD_FIELD} .ProseMirror`).first().click();
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    for (let line = 1; line <= lines; line++) {
      if (line > 1) await page.keyboard.press("Shift+Enter");
      await page.keyboard.insertText(`Line ${line}: keep retries in sync.`);
    }
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
  };

  type Measured = { line: number | null; controls: Record<string, number | null> };
  const measure = (page: Page) =>
    page.evaluate(
      ({ COMPOSER_MD_FIELD, PLUS_PICKER }): Measured => {
        const field = document.querySelector<HTMLElement>(COMPOSER_MD_FIELD);
        const box = field?.closest(".acpmux-composer-box");
        const shown = (element: Element | null | undefined) => {
          if (!element) return null;
          const rect = element.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 ? rect : null;
        };
        const centre = (selector: string) => {
          const rect = shown([...(box?.querySelectorAll(selector) ?? [])].find((element) => shown(element)));
          return rect ? (rect.top + rect.bottom) / 2 : null;
        };
        // The last visible line: the last text line's box inside the field's visible area.
        let line: number | null = null;
        const view = field?.getBoundingClientRect();
        const blocks = [...(field?.querySelectorAll(".ProseMirror > *") ?? [])];
        if (view)
          for (const block of blocks.reverse()) {
            const range = document.createRange();
            range.selectNodeContents(block);
            const rects = [...range.getClientRects()].filter(
              (rect) => rect.height > 0 && rect.top >= view.top - 1 && rect.bottom <= view.bottom + 1,
            );
            const last = rects.at(-1);
            if (last) {
              line = (last.top + last.bottom) / 2;
              break;
            }
          }
        return {
          line,
          controls: {
            plus: centre(PLUS_PICKER),
            mic: centre(".acpmux-mic"),
            send: centre(".acpmux-send"),
            // Every other control drawn inside the box (outside the draft): none may stay at the top.
            ...Object.fromEntries(
              [...(box?.querySelectorAll<HTMLElement>("button, [role=button]") ?? [])]
                .filter((element) => !field?.contains(element) && shown(element))
                .map((element, index) => {
                  const rect = element.getBoundingClientRect();
                  const name =
                    element.getAttribute("aria-label") || element.className.toString().split(" ")[0] || "control";
                  return [`${name}#${index}`, (rect.top + rect.bottom) / 2];
                }),
            ),
          },
        };
      },
      { COMPOSER_MD_FIELD, PLUS_PICKER },
    );

  for (const width of [400, 1100])
    for (const lines of [1, 3, 8, PAST_CAP])
      test(`controls on the last line: ${lines} line(s) at ${width} px`, async () => {
        const page = await open(width);
        try {
          await typeLines(page, lines);
          const { line, controls } = await measure(page);
          expect(line).not.toBeNull();
          const drawn = Object.entries(controls).filter(([, value]) => value !== null);
          expect(drawn.map(([name]) => name)).toContain("plus");
          for (const [name, value] of drawn)
            expect({ name, off: Math.abs(value! - line!) <= TOLERANCE ? 0 : value! - line! }).toEqual({ name, off: 0 });
        } finally {
          await page.close();
        }
      });

  test("the thumb shows only for a moment after a length change or a scroll", async () => {
    const page = await open(400);
    try {
      await typeLines(page, PAST_CAP);
      const scroller = `${COMPOSER_MD_FIELD}[${MINIMAL_SCROLLER_ATTRIBUTE}], ${COMPOSER_MD_FIELD} [${MINIMAL_SCROLLER_ATTRIBUTE}]`;
      await page.locator(scroller).first().waitFor({ state: "attached" });
      const state = () =>
        page.evaluate(
          ({ scroller, SCROLLING_ATTRIBUTE }) => {
            const element = document.querySelector<HTMLElement>(scroller)!;
            return {
              overflows: element.scrollHeight > element.clientHeight + 1,
              marked: element.hasAttribute(SCROLLING_ATTRIBUTE),
              ink: getComputedStyle(element).getPropertyValue("--cmux-shown-scroller-ink").trim(),
            };
          },
          { scroller, SCROLLING_ATTRIBUTE },
        );
      await page.waitForTimeout(REST_MS);
      const rest = await state();
      expect(rest.overflows).toBe(true);
      expect(rest).toMatchObject({ marked: false, ink: "0%" });

      // A line added past the cap shows it.
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.insertText("One more line.");
      await page.waitForFunction(
        ({ scroller, SCROLLING_ATTRIBUTE }) => document.querySelector(scroller)?.hasAttribute(SCROLLING_ATTRIBUTE),
        { scroller, SCROLLING_ATTRIBUTE },
        { timeout: 1_000 },
      );
      await page.waitForTimeout(REST_MS);
      expect((await state()).marked).toBe(false);

      // A wheel scroll over the draft shows it.
      const rect = (await page.locator(scroller).first().boundingBox())!;
      await page.mouse.move(rect.x + rect.width / 2, rect.y + rect.height / 2);
      await page.mouse.wheel(0, -120);
      await page.waitForFunction(
        ({ scroller, SCROLLING_ATTRIBUTE }) => document.querySelector(scroller)?.hasAttribute(SCROLLING_ATTRIBUTE),
        { scroller, SCROLLING_ATTRIBUTE },
        { timeout: 1_000 },
      );
      await page.mouse.move(0, 0);
      await page.waitForTimeout(REST_MS);
      expect((await state()).marked).toBe(false);
    } finally {
      await page.close();
    }
  });
});
