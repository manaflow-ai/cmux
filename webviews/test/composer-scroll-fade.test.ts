// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// A long prompt fades at the composer's edges (Leo 2026-10-21: "A fade mask at the top edge (and
// bottom when not at the end) covers the text ... when content is scrolled out of view"). The prompt
// scrolls inside its own box past eight lines (.acpmux-md-field, markdownField.css); the edge with
// more draft past it is marked (`data-fade-top`, `data-fade-bottom`) and faded with an alpha mask,
// so whatever is behind the composer's glass shows through: nothing is painted over the text.
//
// The pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// (support/papercutChat.ts). Real Chromium and WebKit (the app's engine); CI fails the file when it
// cannot launch them (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/composer-scroll-fade.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";

await requireBrowserLane("composer-scroll-fade.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      throw new Error(`composer-scroll-fade: cannot launch ${engine[0]}`);
    }
  }
  const browsers = new Map<string, Browser>();
  let current: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    pane = await papercutPane(() => current!, { turns: 4, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    current = browsers.values().next().value;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await pane?.close();
  });

  const FIELD = ".acpmux-composer-prompt";
  const EDITABLE = ".acpmux-composer-prompt [contenteditable='true']";

  const settle = (page: Page) =>
    page
      .evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(() => done(undefined)))))
      .then(() => page.waitForTimeout(150));

  /// The prompt's scroll position, its edge marks and its computed mask.
  const edges = (page: Page) =>
    page.evaluate((selector) => {
      const field = document.querySelector<HTMLElement>(selector)!;
      const style = getComputedStyle(field) as CSSStyleDeclaration & { webkitMaskImage?: string };
      const mask = style.maskImage && style.maskImage !== "" ? style.maskImage : (style.webkitMaskImage ?? "none");
      return {
        top: field.scrollTop,
        end: field.scrollHeight - field.clientHeight,
        fadeTop: field.hasAttribute("data-fade-top"),
        fadeBottom: field.hasAttribute("data-fade-bottom"),
        mask,
        webkitMask: style.webkitMaskImage ?? style.getPropertyValue("-webkit-mask-image"),
      };
    }, FIELD);

  /// Pastes `lines` lines into the prompt, as the clipboard would.
  async function paste(page: Page, lines: number) {
    await page.locator(EDITABLE).click();
    await page.evaluate(
      ({ selector, count }) => {
        const field = document.querySelector<HTMLElement>(selector)!;
        const data = new DataTransfer();
        // Long lines: the draft overflows the field's eight lines however the pasted lines wrap or join.
        const lines = Array.from(
          { length: count },
          (_, i) => `draft line ${i + 1}: keep the retry rules and the tests in sync with the docs.`,
        );
        data.setData("text/plain", lines.join("\n"));
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { selector: EDITABLE, count: lines },
    );
    await page.waitForFunction(({ selector, last }) => document.querySelector(selector)?.textContent?.includes(last), {
      selector: EDITABLE,
      last: `draft line ${lines}:`,
    });
    await settle(page);
    // The paste overflows the field's cap, so it scrolls inside.
    expect((await edges(page)).end).toBeGreaterThan(100);
  }

  async function scrollTo(page: Page, at: "middle" | "top" | "end") {
    await page.evaluate(
      ({ selector, at }) => {
        const field = document.querySelector<HTMLElement>(selector)!;
        const end = field.scrollHeight - field.clientHeight;
        field.scrollTop = at === "top" ? 0 : at === "end" ? end : Math.round(end / 2);
      },
      { selector: FIELD, at },
    );
    await settle(page);
  }

  /// The pixel at (`x`, `y`) as the page draws it, [r, g, b].
  async function pixel(page: Page, x: number, y: number): Promise<number[]> {
    const png = await page.screenshot({ clip: { x: Math.round(x), y: Math.round(y), width: 1, height: 1 } });
    return page.evaluate(async (base64) => {
      const image = new Image();
      image.src = `data:image/png;base64,${base64}`;
      await image.decode();
      const canvas = document.createElement("canvas");
      canvas.width = image.width;
      canvas.height = image.height;
      const context = canvas.getContext("2d")!;
      context.drawImage(image, 0, 0);
      return Array.from(context.getImageData(0, 0, 1, 1).data.slice(0, 3));
    }, png.toString("base64"));
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("a long draft fades at the edge with more draft past it, a short one at neither", async () => {
        current = browsers.get(name);
        const page = await pane!.open();

        // A short draft fits: no edge marks, no mask.
        await page.locator(EDITABLE).click();
        await page.keyboard.type("a short draft");
        await settle(page);
        let seen = await edges(page);
        expect(seen.end).toBeLessThanOrEqual(0);
        expect([seen.fadeTop, seen.fadeBottom, seen.mask]).toEqual([false, false, "none"]);

        // A 40-line paste shows its end: the top fades, the bottom does not.
        await page.keyboard.press("ControlOrMeta+A");
        await page.keyboard.press("Backspace");
        await paste(page, 40);
        seen = await edges(page);
        expect(seen.end).toBeGreaterThan(100);
        expect(seen.end - seen.top).toBeLessThan(2);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, false]);
        expect(seen.mask).toContain("gradient");

        // The wheel up to the top: the bottom fades, the top does not.
        const box = (await page.locator(FIELD).boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.wheel(0, -4000);
        await page.waitForTimeout(400);
        await settle(page);
        seen = await edges(page);
        expect(seen.top).toBe(0);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([false, true]);
        expect(seen.mask).toContain("gradient");

        // In the middle both edges fade.
        await scrollTo(page, "middle");
        seen = await edges(page);
        expect(seen.top).toBeGreaterThan(0);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, true]);
        expect(seen.mask).toContain("gradient");

        // Back at the end, the bottom mark goes again; cut back to a short draft, both go and so does the mask.
        await scrollTo(page, "end");
        seen = await edges(page);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, false]);
        await page.keyboard.press("ControlOrMeta+A");
        await page.keyboard.type("short again");
        await settle(page);
        seen = await edges(page);
        expect([seen.fadeTop, seen.fadeBottom, seen.mask]).toEqual([false, false, "none"]);
        await page.close();
      });

      // coord-deputy 2026-10-21: the composer sits on glass, so the fade must be an alpha mask on the
      // scroller, never a painted gradient, pseudo-element or overlay that would turn opaque there.
      test("the faded edge is see-through: what is behind the prompt shows, nothing covers it", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await paste(page, 40);
        await scrollTo(page, "middle");
        const seen = await edges(page);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, true]);
        // An alpha mask on the scroller itself, in WebKit's prefixed form too.
        expect(seen.mask).toContain("linear-gradient");
        expect(seen.webkitMask).toContain("linear-gradient");

        const box = (await page.locator(FIELD).boundingBox())!;
        const x = box.x + box.width / 2;
        // Nothing (no pseudo-element's host, no sibling) lies over the faded bands: a point in each
        // hits the prompt's own content.
        const hits = await page.evaluate(
          ({ selector, x, top, bottom }) => {
            const field = document.querySelector(selector)!;
            return [top, bottom].map((y) => {
              const hit = document.elementFromPoint(x, y);
              return hit ? field.contains(hit) : false;
            });
          },
          { selector: FIELD, x, top: box.y + 4, bottom: box.y + box.height - 4 },
        );
        expect(hits).toEqual([true, true]);

        // The draft's text block drawn solid red: at the faded top row it is (nearly) gone and the
        // pixel is what the page draws there with no draft at all; mid-field it is solid red.
        await page.addStyleTag({
          content: `${EDITABLE} { background: rgb(255, 0, 0) !important; color: rgb(255, 0, 0) !important; caret-color: transparent !important; }`,
        });
        await settle(page);
        const middle = await pixel(page, x, box.y + box.height / 2);
        expect(middle[0]).toBeGreaterThan(200);
        expect(middle[1]).toBeLessThan(60);
        expect(middle[2]).toBeLessThan(60);
        const faded = await pixel(page, x, box.y + 1);
        await page.addStyleTag({ content: `${EDITABLE} { visibility: hidden !important; }` });
        await settle(page);
        const backdrop = await pixel(page, x, box.y + 1);
        for (let channel = 0; channel < 3; channel++)
          expect(Math.abs(faded[channel]! - backdrop[channel]!)).toBeLessThan(40);
        await page.close();
      });

      test("Reduce Transparency keeps plain edges", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
        await paste(page, 40);
        await scrollTo(page, "middle");
        const seen = await edges(page);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, true]);
        expect(seen.mask).toBe("none");
        await page.close();
      });
    });
  }
});
