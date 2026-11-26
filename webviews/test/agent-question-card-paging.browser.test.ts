// cmux-web-test-timeout: 600
// The multi-question "Needs your input" card holds still while it pages (cmux#56534; the user, on
// clicking Next: "i dont like how there is layout shift"). On the gallery's three questions of very
// different lengths, the last with option previews (agent-pane.question-card, pending-paging-uneven):
//
// 1. Stepping through every question with the pager's arrows, then back, and with the footer's Next,
//    the card, its title, its rows, its last row, Skip, Next/Send, the pager and the × keep their
//    boxes, in a pane narrow enough to wrap the last row, a narrow and a wide one, and at a larger
//    interface scale.
// 2. The pager's and the ×'s tooltips open above the bar, never over the question under it.
// 3. The bar's icons share one set: the pager's two chevrons are the same glyph, the × is the pack's
//    close, and every glyph on the card grows with --cmux-interface-scale as its words do.
//
// Chromium on the gallery stage; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-question-card-paging.browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-question-card-paging: skipping (run `bunx playwright install chromium`)");
    describe.skip("agent question card paging", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.question-card";
  const VARIANT = "pending-paging-uneven";
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;

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

  const open = async (width: number, scale = 1): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width, height: 900 }, deviceScaleFactor: 2 });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    if (scale !== 1)
      await page.evaluate(
        (scale) => document.documentElement.style.setProperty("--cmux-interface-scale", String(scale)),
        scale,
      );
    await page.locator(".acpmux-question-position").waitFor();
    await page.evaluate(() => document.fonts.ready);
    return page;
  };

  const PARTS = {
    card: ".acpmux-question-ask",
    title: ".acpmux-question-head",
    rows: ".acpmux-question-pages > .acpmux-question-body:not([aria-hidden]) > .acpmux-question-rows",
    footer: ".acpmux-question-footer",
    skip: ".acpmux-question-skip",
    submit: ".acpmux-question-submit",
    pager: ".acpmux-question-navigation",
    dismiss: ".acpmux-question-bar .ui-dismiss",
  };
  type Boxes = Record<keyof typeof PARTS, { x: number; y: number; width: number; height: number }>;
  const boxes = (page: Page) =>
    page.evaluate((parts) => {
      const out: Record<string, { x: number; y: number; width: number; height: number }> = {};
      for (const [name, selector] of Object.entries(parts)) {
        const element = document.querySelector(selector);
        if (!element) throw new Error(`missing ${name}: ${selector}`);
        const { x, y, width, height } = element.getBoundingClientRect();
        out[name] = { x, y, width, height };
      }
      return out as Boxes;
    }, PARTS);
  const position = async (page: Page) => (await page.locator(".acpmux-question-position").innerText()).trim();
  const prompt = async (page: Page) => (await page.locator(".acpmux-question-prompt").innerText()).trim();
  const settle = (page: Page) =>
    page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));

  const expectSame = (label: string, first: Boxes, now: Boxes) => {
    for (const name of Object.keys(PARTS) as (keyof typeof PARTS)[]) {
      for (const edge of ["x", "y", "width", "height"] as const) {
        const moved = Math.abs(now[name][edge] - first[name][edge]);
        if (moved > TOLERANCE)
          throw new Error(`${label}: ${name}.${edge} moved ${first[name][edge]} -> ${now[name][edge]}`);
      }
    }
  };

  describe("agent question card paging", () => {
    for (const [width, scale] of [
      // Narrow enough that Skip and Send wrap under the typed answer.
      [340, 1],
      [420, 1],
      [820, 1],
      [640, 1.25],
    ] as const) {
      test(`paging moves nothing at ${width} px, scale ${scale}`, async () => {
        const page = await open(width, scale);
        expect(await position(page)).toBe("1 of 3");
        const prompts = [await prompt(page)];
        const first = await boxes(page);
        const step = async (selector: string, expected: string) => {
          await page.locator(selector).click();
          await settle(page);
          expect(await position(page)).toBe(expected);
          const now = await boxes(page);
          expectSame(`${expected} (${width} px, ${scale}x)`, first, now);
          // The last page's hint gives way before the × does: the × stays inside the card (a long
          // hint pushed it out in a real pane).
          expect(now.dismiss.x + now.dismiss.width).toBeLessThanOrEqual(now.card.x + now.card.width + TOLERANCE);
        };
        const next = ".acpmux-question-nav-button:not([data-step])";
        const previous = '.acpmux-question-nav-button[data-step="previous"]';
        await step(next, "2 of 3");
        prompts.push(await prompt(page));
        await step(next, "3 of 3");
        prompts.push(await prompt(page));
        // The questions differ: a page that drew the same question would prove nothing.
        expect(new Set(prompts).size).toBe(3);
        // The last page says Send and names what it still waits for, in the bar, on one line.
        expect((await page.locator(".acpmux-question-submit").innerText()).trim()).toBe("Send");
        expect(await page.locator(".acpmux-question-bar .acpmux-question-hint").count()).toBe(1);
        await step(previous, "2 of 3");
        await step(previous, "1 of 3");
        // The footer's Next steps too, from the title's long question to the next one.
        expect((await page.locator(".acpmux-question-submit").innerText()).trim()).toBe("Next");
        await step(".acpmux-question-submit", "2 of 3");
        await page.close();
      });
    }

    test("the pager's and the ×'s tooltips open above the bar, off the question", async () => {
      const page = await open(640);
      // In the pane the asks stack scrolls, as tall as its card (bottomStack.css), so the room above
      // the bar is outside it: the tooltip still opens there, not below over the question.
      await page.evaluate(() => {
        const stack = document.querySelector<HTMLElement>(".acpmux-asks-stack")!;
        stack.style.overflowY = "auto";
        stack.style.overscrollBehavior = "contain";
      });
      const question = await page.locator(".acpmux-question-head").boundingBox();
      // Previous starts disabled on the first page; step on so every control takes a hover.
      await page.locator(".acpmux-question-nav-button:not([data-step])").click();
      const tip = page.locator(".ui-title-tooltip");
      for (const [selector, words] of [
        ['.acpmux-question-nav-button[data-step="previous"]', "Previous Question"],
        [".acpmux-question-nav-button:not([data-step])", "Next Question"],
        [".acpmux-question-bar .ui-dismiss", "Dismiss"],
      ] as const) {
        // The last control's tooltip goes first, so the one measured is this control's.
        await page.mouse.move(0, 0);
        await tip.waitFor({ state: "hidden", timeout: 5_000 });
        await page.locator(selector).hover();
        await tip.waitFor({ state: "visible", timeout: 5_000 });
        expect((await tip.innerText()).trim()).toBe(words);
        const box = (await tip.boundingBox())!;
        const bar = (await page.locator(".acpmux-question-bar").boundingBox())!;
        expect(box.y + box.height).toBeLessThanOrEqual(bar.y + bar.height / 2);
        expect(box.y + box.height).toBeLessThanOrEqual(question!.y);
      }
      await page.close();
    });

    test("the card's icons are one set and grow with the interface scale", async () => {
      const glyphs = async (page: Page) =>
        page.evaluate(() => {
          const size = (selector: string) => {
            const svg = document.querySelector<SVGElement>(selector);
            if (!svg) throw new Error(`missing ${selector}`);
            return svg.getBoundingClientRect().width;
          };
          const icon = (selector: string) => document.querySelector(selector)?.getAttribute("data-icon");
          return {
            previous: icon('.acpmux-question-nav-button[data-step="previous"] > svg'),
            next: icon(".acpmux-question-nav-button:not([data-step]) > svg"),
            dismiss: icon(".acpmux-question-bar .ui-dismiss > svg"),
            sizes: {
              mark: size(".acpmux-question-bar > span > svg"),
              chevron: size(".acpmux-question-nav-button > svg"),
              dismiss: size(".acpmux-question-bar .ui-dismiss > svg"),
              tile: document
                .querySelector(
                  ".acpmux-question-row .acpmux-question-number, .acpmux-question-row .acpmux-question-mark",
                )!
                .getBoundingClientRect().height,
            },
          };
        });
      const base = await open(640);
      const one = await glyphs(base);
      await base.close();
      expect(one.previous).toBe("disclosure.collapsed");
      expect(one.next).toBe("disclosure.collapsed");
      expect(one.dismiss).toBe("action.close");
      // The icon scale: 14 for the mark inline with its words, 12 for the chevrons and the ×.
      expect(one.sizes.mark).toBeCloseTo(14, 1);
      expect(one.sizes.chevron).toBeCloseTo(12, 1);
      expect(one.sizes.dismiss).toBeCloseTo(12, 1);
      const large = await open(640, 1.25);
      const big = await glyphs(large);
      await large.close();
      for (const name of Object.keys(one.sizes) as (keyof typeof one.sizes)[])
        expect(big.sizes[name]).toBeCloseTo(one.sizes[name] * 1.25, 1);
    });
  });
});
