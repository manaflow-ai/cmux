// cmux-web-test-timeout: 300
// The Show more / Show less row under every block the transcript cuts is the whole bottom row of
// its block (Leo, 2026-11-07: "what if the whole bottom row area were clickable in this, like, show
// more show less area? And I mean likewise for the other bits ... my mouse is in the general
// vicinity, it's in the general height area"): a click anywhere along it (its left edge, middle and
// right edge) toggles the block, for a Shell block and a call's output past the 400 lines drawn of
// their end (Show all output), a search's files and a long sent prompt. Pointing at it moves nothing
// ("make sure you don't accidentally ... push out different kinds of layout"). An edit's diff and a
// file read have no row: past eight lines they scroll in their box (Leo, 2026-11-12: "this is a
// really useless show all 9 lines").
//
// It renders `agent-pane.expand-row` on the gallery stage in Chromium, dark and light.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/expand-row.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { BLOCKS, CARD, ROW, type Block } from "../src/agent-session/acpmux/conversation/ExpandRow.gallery";

await requireBrowserLane("expand-row.test.ts", async () => {
  const ENTRY = "agent-pane.expand-row";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("expand row", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const stageURL = (variant: string, theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant, frame: "component", width: 680, theme })}`;

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

  /** Resolves once nothing on the page is easing (a looping animation never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (variant: string, theme: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 680, height: 900 } });
    for (;;) {
      await page.goto(stageURL(variant, theme));
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
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.mouse.move(1, 1);
    await eased(page);
    return page;
  };

  const expanded = (page: Page, block: Block) =>
    page.evaluate((row) => document.querySelector(row)?.getAttribute("aria-expanded"), ROW[block]);

  /** The block's box (its card, or the prompt's bubble). */
  const cardBox = async (page: Page, block: Block) => {
    const box = await page.locator(CARD[block]).first().boundingBox();
    if (!box) throw new Error(`${block}: no ${CARD[block]}`);
    return box;
  };

  for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"]) {
    for (const block of BLOCKS) {
      test(`${theme} ${block}: a click anywhere along the bottom row toggles it`, async () => {
        const page = await open(block, theme);
        try {
          expect(await expanded(page, block)).toBe("false");
          let state = "false";
          for (const at of ["left", "middle", "right"] as const) {
            const card = await cardBox(page, block);
            // In the row's height, 6px above the block's bottom edge, 6px in from its sides.
            const x = at === "left" ? card.x + 6 : at === "right" ? card.x + card.width - 6 : card.x + card.width / 2;
            const y = card.y + card.height - 6;
            await page.mouse.click(x, y);
            await eased(page);
            const next = state === "false" ? "true" : "false";
            expect({ at, expanded: await expanded(page, block) }).toEqual({ at, expanded: next });
            state = next;
          }
          // One button: keyboard focus shows a ring, and Enter toggles it.
          await page.locator(ROW[block]).first().focus();
          await page.keyboard.press("Enter");
          await eased(page);
          expect(await expanded(page, block)).toBe(state === "false" ? "true" : "false");
        } finally {
          await page.close();
        }
      });

      test(`${theme} ${block}: pointing at the row moves no box`, async () => {
        for (const variant of [block, `${block}-expanded`]) {
          const page = await open(variant, theme);
          try {
            const boxes = () =>
              page.evaluate(() =>
                [...document.querySelectorAll("[data-gallery-block] *")].map((element) => {
                  const box = element.getBoundingClientRect();
                  return `${element.tagName}.${element.className}: ${box.x},${box.y},${box.width},${box.height}`;
                }),
              );
            const before = await boxes();
            const row = await page.locator(ROW[block]).first().boundingBox();
            const card = await cardBox(page, block);
            // The row's middle, and its right end (a row that is the block's full width is under it).
            await page.mouse.move(row!.x + row!.width / 2, row!.y + row!.height / 2);
            await eased(page);
            expect(await boxes()).toEqual(before);
            await page.mouse.move(card.x + card.width - 6, card.y + card.height - 6);
            await eased(page);
            const hover = await page.evaluate((selector) => {
              const element = document.querySelector<HTMLElement>(selector)!;
              return { hovered: element.matches(":hover"), cursor: getComputedStyle(element).cursor };
            }, ROW[block]);
            expect(hover).toEqual({ hovered: true, cursor: "default" });
            expect(await boxes()).toEqual(before);
          } finally {
            await page.close();
          }
        }
      });
    }

    // Leo, 2026-11-11: "the whole line should not be highlighted. Just the text. The text. The point
    // is that it looks like you're clicking just the text, but the whole clickable range is the whole
    // thing." The pointer anywhere on the row lights the words' own box and nothing else; the row stays
    // the target (the click test above).
    for (const block of BLOCKS) {
      test(`${theme} ${block}: the pointer lights the words alone, never the row`, async () => {
        for (const variant of [block, `${block}-expanded`]) {
          const page = await open(variant, theme);
          try {
            const look = () =>
              page.evaluate((selector) => {
                const clear = (color: string) => color === "transparent" || /rgba\(.*,\s*0\)$/.test(color);
                const row = document.querySelector<HTMLElement>(selector)!;
                const label = row.querySelector<HTMLElement>(".cv-expand-row__label")!;
                const range = document.createRange();
                range.selectNodeContents(label);
                const words = range.getBoundingClientRect();
                const lit = label.getBoundingClientRect();
                const rowBox = row.getBoundingClientRect();
                return {
                  rowFill: clear(getComputedStyle(row).backgroundColor)
                    ? "clear"
                    : getComputedStyle(row).backgroundColor,
                  labelFill: !clear(getComputedStyle(label).backgroundColor),
                  // How far the lit box reaches past the words on each side.
                  reach: [
                    words.left - lit.left,
                    lit.right - words.right,
                    words.top - lit.top,
                    lit.bottom - words.bottom,
                  ],
                  row: { x: rowBox.x, y: rowBox.y, width: rowBox.width, height: rowBox.height },
                  words: { left: words.left, right: words.right },
                };
              }, ROW[block]);
            const rest = await look();
            expect({ variant, rest: rest.labelFill, row: rest.rowFill }).toEqual({
              variant,
              rest: false,
              row: "clear",
            });
            // On the row's far end, well away from the words, and on its middle.
            for (const x of [rest.row.x + rest.row.width - 4, rest.row.x + rest.row.width / 2]) {
              if (x > rest.words.left - 8 && x < rest.words.right + 8) continue;
              await page.mouse.move(x, rest.row.y + rest.row.height / 2);
              await eased(page);
              const hover = await look();
              expect({ variant, x: Math.round(x), row: hover.rowFill, words: hover.labelFill }).toEqual({
                variant,
                x: Math.round(x),
                row: "clear",
                words: true,
              });
              // The lit box is the words' own, within a few pixels of them on every side.
              for (const side of hover.reach) expect(side).toBeGreaterThanOrEqual(-0.5);
              for (const side of hover.reach) expect(side).toBeLessThanOrEqual(8.5);
            }
            // Off the row, nothing is lit.
            await page.mouse.move(1, 1);
            await eased(page);
            expect((await look()).labelFill).toBe(false);
          } finally {
            await page.close();
          }
        }
      });
    }

    // A sent prompt's bubble insets its text and its Show more / Show less row the same on the left
    // as on the right, collapsed and expanded.
    test(`${theme} prompt: the bubble's left and right insets are equal`, async () => {
      for (const variant of ["prompt", "prompt-expanded"]) {
        const page = await open(variant, theme);
        try {
          const insets = await page.evaluate(
            ({ card, row }) => {
              const bubble = document.querySelector<HTMLElement>(card)!;
              const button = document.querySelector<HTMLElement>(row)!;
              const style = getComputedStyle(bubble);
              const box = bubble.getBoundingClientRect();
              const rowBox = button.getBoundingClientRect();
              const rowStyle = getComputedStyle(button);
              return {
                bubble: [parseFloat(style.paddingLeft), parseFloat(style.paddingRight)],
                // The row reaches the bubble's edges and insets its words by the bubble's padding.
                rowEdges: [rowBox.left - box.left, box.right - rowBox.right],
                rowInsets: [parseFloat(rowStyle.paddingLeft), parseFloat(rowStyle.paddingRight)],
              };
            },
            { card: CARD.prompt, row: ROW.prompt },
          );
          const [left, right] = insets.bubble;
          expect(Math.abs(left! - right!)).toBeLessThanOrEqual(1);
          expect(Math.abs(insets.rowEdges[0]!) + Math.abs(insets.rowEdges[1]!)).toBeLessThanOrEqual(1);
          expect(Math.abs(insets.rowInsets[0]! - left!)).toBeLessThanOrEqual(1);
          expect(Math.abs(insets.rowInsets[1]! - right!)).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      }
    });

    for (const block of BLOCKS) {
      test(`${theme} ${block}: no fade lies over the row`, async () => {
        for (const variant of [block, `${block}-expanded`]) {
          const page = await open(variant, theme);
          try {
            // Every box from the row out to the stage: none masks it (a cut block's fade is on its
            // lines, beside the row, never on a box that holds the row).
            const masked = await page.evaluate((row) => {
              const found: string[] = [];
              const stage = document.querySelector("[data-gallery-block]");
              for (let node = document.querySelector(row); node && node !== stage; node = node.parentElement) {
                const style = getComputedStyle(node);
                const mask = style.maskImage || style.getPropertyValue("-webkit-mask-image");
                if (mask && mask !== "none") found.push(`${node.className}: ${mask}`);
                if (parseFloat(style.opacity) < 1) found.push(`${node.className}: opacity ${style.opacity}`);
              }
              return found;
            }, ROW[block]);
            expect({ variant, masked }).toEqual({ variant, masked: [] });
          } finally {
            await page.close();
          }
        }
      });
    }
  }
});
