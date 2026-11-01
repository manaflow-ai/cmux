// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// A long prompt fades at the composer's edges (Leo 2026-10-21: "A fade mask at the top edge (and
// bottom when not at the end) covers the text ... when content is scrolled out of view"). The prompt
// scrolls inside its own box past eight lines (.acpmux-md-field, markdownField.css); the edge with
// more draft past it is marked (`data-fade-top`, `data-fade-bottom`) and faded with an alpha mask,
// so whatever is behind the composer's glass shows through: nothing is painted over the text.
// The attachment row above the prompt (.acpmux-attachments, composerAttachments.css) scrolls sideways
// past the composer's width and fades the same way at the side with more chips past it
// (`data-fade-left`, `data-fade-right`), with the prompt's band (`--acpmux-md-fade-band`).
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

  /// Three painted frames: a paste's own scroll to its end runs a frame after it, and the edge marks
  /// follow that scroll's event.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise((done) =>
          requestAnimationFrame(() => requestAnimationFrame(() => requestAnimationFrame(() => done(undefined)))),
        ),
    );

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

  /// Pastes `lines` lines into the prompt, as the clipboard would. `markup` lines carry a tag-like
  /// `<Retry>`, which the field inserts as plain text on its own paste path (looksLikeMarkupText), and
  /// end in a newline, as text copied from an editor does: the caret then sits on an empty last line.
  async function paste(page: Page, lines: number, markup = false) {
    await page.locator(EDITABLE).click();
    await page.evaluate(
      ({ selector, count, markup }) => {
        const field = document.querySelector<HTMLElement>(selector)!;
        const data = new DataTransfer();
        // Long lines: the draft overflows the field's eight lines however the pasted lines wrap or join.
        // At most 20 of them, under 2,000 characters: a larger paste is a chip (pastedText.ts).
        const lines = Array.from(
          { length: count },
          (_, i) =>
            `draft line ${i + 1}: keep the ${markup ? "<Retry> " : ""}retry rules and the tests in sync with the docs, and say why.`,
        );
        data.setData("text/plain", lines.join("\n") + (markup ? "\n" : ""));
        field.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      },
      { selector: EDITABLE, count: lines, markup },
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

  const ROW = ".acpmux-composer .acpmux-attachments";
  const CHIP = ".acpmux-composer .acpmux-attachment-pasted";

  /// Pastes `count` texts of 30 lines each, every one a Pasted text chip (over pastedText.ts's 20
  /// lines), so the attachment row holds `count` more chips.
  /// The row is Settings' attachment strip (the default inline view puts chips in the text), so the
  /// strip is turned on first.
  async function pasteChips(page: Page, count: number) {
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ attachmentView: "strip" }));
    await page.locator(EDITABLE).click();
    const held = await page.locator(CHIP).count();
    for (let chip = held + 1; chip <= held + count; chip++) {
      await page.evaluate(
        ({ selector, chip }) => {
          const data = new DataTransfer();
          const lines = Array.from({ length: 30 }, (_, i) => `pasted ${chip} line ${i + 1}: the retry rules.`);
          data.setData("text/plain", lines.join("\n"));
          document
            .querySelector(selector)!
            .dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
        },
        { selector: EDITABLE, chip },
      );
      await page.waitForFunction(({ selector, chip }) => document.querySelectorAll(selector).length === chip, {
        selector: CHIP,
        chip,
      });
    }
    await settle(page);
  }

  /// The attachment row's scroll position, its edge marks, its bands and its computed mask, with the
  /// prompt's own band (FADE_BAND_PX, MarkdownField.tsx) to measure them against.
  const rowEdges = (page: Page) =>
    page.evaluate(
      ({ row, field }) => {
        const node = document.querySelector<HTMLElement>(row)!;
        const style = getComputedStyle(node) as CSSStyleDeclaration & { webkitMaskImage?: string };
        const mask = style.maskImage && style.maskImage !== "" ? style.maskImage : (style.webkitMaskImage ?? "none");
        const px = (name: string) => parseFloat(style.getPropertyValue(name) || "0");
        return {
          left: node.scrollLeft,
          end: node.scrollWidth - node.clientWidth,
          fadeLeft: node.hasAttribute("data-fade-left"),
          fadeRight: node.hasAttribute("data-fade-right"),
          bandLeft: px("--acpmux-attach-fade-left"),
          bandRight: px("--acpmux-attach-fade-right"),
          promptBand: parseFloat(
            getComputedStyle(document.querySelector(field)!).getPropertyValue("--acpmux-md-fade-band"),
          ),
          mask,
          webkitMask: style.webkitMaskImage ?? style.getPropertyValue("-webkit-mask-image"),
        };
      },
      { row: ROW, field: FIELD },
    );

  /// Scrolls the attachment row to its start, its end, or a middle position where a chip crosses
  /// each edge by a few pixels at least (no gap between chips sits at either edge).
  async function scrollRow(page: Page, at: "start" | "middle" | "end") {
    await page.evaluate(
      ({ row, chip, at }) => {
        const node = document.querySelector<HTMLElement>(row)!;
        const end = node.scrollWidth - node.clientWidth;
        if (at !== "middle") {
          node.scrollLeft = at === "start" ? 0 : end;
          return;
        }
        const covered = (x: number) =>
          Array.from(node.querySelectorAll(chip)).some((element) => {
            const rect = element.getBoundingClientRect();
            return rect.left + 4 <= x && x <= rect.right - 4;
          });
        for (let left = Math.round(end / 2); left < end - 24; left += 4) {
          node.scrollLeft = left;
          const box = node.getBoundingClientRect();
          if (covered(box.left + 1) && covered(box.right - 1)) return;
        }
        throw new Error("no scroll position puts a chip across both edges");
      },
      { row: ROW, chip: CHIP, at },
    );
    await settle(page);
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

        // A 20-line paste shows its end: the top fades, the bottom does not.
        await page.keyboard.press("ControlOrMeta+A");
        await page.keyboard.press("Backspace");
        await paste(page, 20);
        seen = await edges(page);
        expect(seen.end).toBeGreaterThan(100);
        expect(seen.end - seen.top).toBeLessThan(2);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, false]);
        expect(seen.mask).toContain("gradient");

        // The wheel up to the top: the bottom fades, the top does not.
        const box = (await page.locator(FIELD).boundingBox())!;
        await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
        await page.mouse.wheel(0, -4000);
        await page.waitForFunction((selector) => document.querySelector(selector)!.scrollTop === 0, FIELD);
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

      test("a markup-looking paste at the end of the draft shows the draft's end too", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await paste(page, 20, true);
        const seen = await edges(page);
        expect(seen.end).toBeGreaterThan(100);
        // Its last line is clear of the bottom fade: the field is at its end, the bottom edge plain.
        expect(seen.end - seen.top).toBeLessThan(2);
        expect(seen.fadeBottom).toBe(false);
        await page.close();
      });

      test("the caret's line, revealed at the faded top edge, sits clear of the fade", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await paste(page, 20);
        // The caret on line 10, the field at the draft's end; typing there reveals the caret at the
        // field's top edge, which has draft above it and so fades.
        await page.evaluate((selector) => {
          const editable = document.querySelector(selector)!;
          const walker = document.createTreeWalker(editable, NodeFilter.SHOW_TEXT);
          for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            const at = (node.textContent ?? "").indexOf("draft line 10:");
            if (at >= 0) {
              window.getSelection()!.collapse(node, at + "draft".length);
              return;
            }
          }
          throw new Error("no line 10");
        }, EDITABLE);
        await settle(page);
        await scrollTo(page, "end");
        await page.keyboard.type("x");
        await settle(page);
        const gap = await page.evaluate((selector) => {
          const field = document.querySelector<HTMLElement>(selector)!;
          const selection = window.getSelection()!;
          const range = document.createRange();
          range.setStart(selection.focusNode!, selection.focusOffset - 1);
          range.setEnd(selection.focusNode!, selection.focusOffset);
          const caret = range.getBoundingClientRect();
          return {
            typed: range.toString(),
            band: field.hasAttribute("data-fade-top")
              ? parseFloat(getComputedStyle(field).getPropertyValue("--acpmux-md-fade-top"))
              : 0,
            above: caret.top - field.getBoundingClientRect().top,
          };
        }, FIELD);
        expect(gap.typed).toBe("x");
        expect(gap.band).toBeGreaterThan(0);
        // The caret's glyph starts below the band (one pixel for subpixel layout and scroll rounding).
        expect(gap.above).toBeGreaterThanOrEqual(gap.band - 1);
        await page.close();
      });

      // coord-deputy 2026-10-21: the composer sits on glass, so the fade must be an alpha mask on the
      // scroller, never a painted gradient, pseudo-element or overlay that would turn opaque there.
      test("the faded edge is see-through: what is behind the prompt shows, nothing covers it", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await paste(page, 20);
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

        // The draft's text block drawn solid red over a solid green composer: at the faded top row
        // the red is (nearly) gone and the green behind the prompt shows; mid-field it is solid red.
        // A painted overlay (in the composer's own colour or any other) would hide the green.
        await page.addStyleTag({
          content: `${EDITABLE} { background: rgb(255, 0, 0) !important; color: rgb(255, 0, 0) !important; caret-color: transparent !important; }
            .acpmux-composer-box { background: rgb(0, 255, 0) !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }`,
        });
        await settle(page);
        const middle = await pixel(page, x, box.y + box.height / 2);
        expect(middle[0]).toBeGreaterThan(200);
        expect(middle[1]).toBeLessThan(60);
        expect(middle[2]).toBeLessThan(60);
        const faded = await pixel(page, x, box.y + 1);
        expect(faded[0]).toBeLessThan(60);
        expect(faded[1]).toBeGreaterThan(200);
        expect(faded[2]).toBeLessThan(60);
        await page.close();
      });

      test("the attachment row fades at the side with more chips past it, by the prompt's band", async () => {
        current = browsers.get(name);
        const page = await pane!.open();

        // Two chips fit: no edge marks, no mask.
        await pasteChips(page, 2);
        let seen = await rowEdges(page);
        expect(seen.end).toBeLessThanOrEqual(0);
        expect([seen.fadeLeft, seen.fadeRight, seen.mask]).toEqual([false, false, "none"]);

        // Eight overflow the row. At its start only the right side fades, by the prompt's band.
        await pasteChips(page, 6);
        await scrollRow(page, "start");
        seen = await rowEdges(page);
        expect(seen.end).toBeGreaterThan(100);
        expect(seen.promptBand).toBeGreaterThan(0);
        expect([seen.fadeLeft, seen.fadeRight]).toEqual([false, true]);
        expect([seen.bandLeft, seen.bandRight]).toEqual([0, seen.promptBand]);
        expect(seen.mask).toContain("linear-gradient");
        expect(seen.webkitMask).toContain("linear-gradient");

        // In the middle both sides fade, each by the prompt's band.
        await scrollRow(page, "middle");
        seen = await rowEdges(page);
        expect([seen.fadeLeft, seen.fadeRight]).toEqual([true, true]);
        expect([seen.bandLeft, seen.bandRight]).toEqual([seen.promptBand, seen.promptBand]);

        // At the end only the left side does.
        await scrollRow(page, "end");
        seen = await rowEdges(page);
        expect([seen.fadeLeft, seen.fadeRight]).toEqual([true, false]);
        expect([seen.bandLeft, seen.bandRight]).toEqual([seen.promptBand, 0]);
        await page.close();
      });

      test("the attachment row's faded sides are see-through: what is behind the row shows", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await pasteChips(page, 8);
        await scrollRow(page, "middle");
        const seen = await rowEdges(page);
        expect([seen.fadeLeft, seen.fadeRight]).toEqual([true, true]);

        const box = (await page.locator(ROW).boundingBox())!;
        const chip = (await page.locator(CHIP).first().boundingBox())!;
        const y = chip.y + chip.height / 2;
        // Two pixels in from each end: the row runs to the composer box's edge, so its outermost
        // pixel is the box's one-device-pixel rim, which brightens on focus (#23745), not the fade.
        const sides = [box.x + 2, box.x + box.width - 2];
        // Nothing lies over the faded sides: a point in each hits the row's own chips.
        const hits = await page.evaluate(
          ({ row, sides, y }) => {
            const node = document.querySelector(row)!;
            return sides.map((x) => {
              const hit = document.elementFromPoint(x, y);
              return hit ? node.contains(hit) : false;
            });
          },
          { row: ROW, sides, y },
        );
        expect(hits).toEqual([true, true]);

        // The chips drawn solid red over a solid green composer: at each faded side the red is
        // (nearly) gone and the green behind the row shows; mid-row it is solid red. A painted overlay
        // would hide the green.
        await page.addStyleTag({
          content: `${CHIP}, ${CHIP} * { background: rgb(255, 0, 0) !important; color: rgb(255, 0, 0) !important; box-shadow: none !important; outline: none !important; }
            .acpmux-composer-box { background: rgb(0, 255, 0) !important; -webkit-backdrop-filter: none !important; backdrop-filter: none !important; }`,
        });
        await settle(page);
        // Mid-row: the point nearest the row's centre that is on a chip, not in the gap between two.
        const middle = await page.evaluate(
          ({ chip, center, y }) =>
            [0, -12, 12, -24, 24]
              .map((shift) => center + shift)
              .find((x) => document.elementFromPoint(x, y)?.closest(chip)),
          { chip: CHIP, center: box.x + box.width / 2, y },
        );
        expect(middle).toBeDefined();
        const solid = await pixel(page, middle!, y);
        expect(solid[0]).toBeGreaterThan(200);
        expect(solid[1]).toBeLessThan(60);
        expect(solid[2]).toBeLessThan(60);
        for (const x of sides) {
          const faded = await pixel(page, x, y);
          expect(faded[0]).toBeLessThan(60);
          expect(faded[1]).toBeGreaterThan(200);
          expect(faded[2]).toBeLessThan(60);
        }
        await page.close();
      });

      test("Reduce Transparency keeps plain edges", async () => {
        current = browsers.get(name);
        const page = await pane!.open();
        await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
        await paste(page, 20);
        await scrollTo(page, "middle");
        const seen = await edges(page);
        expect([seen.fadeTop, seen.fadeBottom]).toEqual([true, true]);
        expect(seen.mask).toBe("none");
        await page.close();
      });
    });
  }
});
