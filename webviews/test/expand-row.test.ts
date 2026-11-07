// cmux-web-test-timeout: 300
// The Show more / Show less row under every block the transcript cuts is the whole bottom row of
// its block (Leo, 2026-11-07: "what if the whole bottom row area were clickable in this, like, show
// more show less area? And I mean likewise for the other bits ... my mouse is in the general
// vicinity, it's in the general height area"): a click anywhere along it (its left edge, middle and
// right edge) toggles the block, for an edit's diff (in the edited-files card and in a tool row),
// a Shell block, a file read, a call's output and a long sent prompt. Pointing at it moves nothing
// ("make sure you don't accidentally ... push out different kinds of layout"), and the edit's diff
// is one surface: one rim, and the row on the code area's own background ("why is it, like, just
// this hard line cut off here between the green and then the rest of the card situation?").
//
// It renders `agent-pane.expand-row` on the gallery stage in Chromium, dark and light.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/expand-row.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { CARD, ROW, type Block } from "../src/agent-session/acpmux/conversation/ExpandRow.gallery";

await requireBrowserLane("expand-row.test.ts", async () => {
  const ENTRY = "agent-pane.expand-row";
  const BLOCKS: Block[] = ["edited", "diff", "shell", "read", "search", "output", "prompt"];
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

    for (const block of ["edited", "diff"] as const) {
      test(`${theme} ${block}: the diff is one surface, its row on the code area's background`, async () => {
        for (const variant of [block, `${block}-expanded`]) {
          const page = await open(variant, theme);
          try {
            const surface = await page.evaluate(
              ({ card, row }) => {
                const clear = (color: string) => color === "transparent" || /rgba\(.*,\s*0\)$/.test(color);
                const rim = (element: Element, pseudo?: string) => {
                  const style = getComputedStyle(element, pseudo);
                  return (
                    style.boxShadow !== "none" ||
                    ["Top", "Right", "Bottom", "Left"].some(
                      (side) =>
                        parseFloat(style.getPropertyValue(`border-${side.toLowerCase()}-width`)) > 0 &&
                        style.getPropertyValue(`border-${side.toLowerCase()}-style`) !== "none" &&
                        !clear(style.getPropertyValue(`border-${side.toLowerCase()}-color`)),
                    )
                  );
                };
                const body = document.querySelector(".cv-edit-diff__body")!;
                const top = document.querySelector(card)!;
                // Every container from the diff's lines out to its card that paints a fill or a rim.
                const painted: string[] = [];
                for (let node: Element | null = body; node; node = node.parentElement) {
                  const style = getComputedStyle(node);
                  const fill = !clear(style.backgroundColor) || style.backgroundImage !== "none";
                  if (fill || rim(node) || rim(node, "::after") || rim(node, "::before"))
                    painted.push(
                      `${node.className}${fill ? " fill" : ""}${rim(node) || rim(node, "::after") ? " rim" : ""}`,
                    );
                  if (node === top) break;
                }
                // The first painted box behind the row and behind the code area.
                const behind = (element: Element | null) => {
                  for (let node = element; node; node = node.parentElement) {
                    const color = getComputedStyle(node).backgroundColor;
                    if (!clear(color)) return { node: node.className, color };
                  }
                  return undefined;
                };
                const button = document.querySelector(row)!;
                return {
                  painted,
                  rowFill: getComputedStyle(button).backgroundColor,
                  seam: JSON.stringify(behind(button)) === JSON.stringify(behind(body)),
                };
              },
              { card: CARD[block], row: ROW[block] },
            );
            expect({ variant, painted: surface.painted.length }).toEqual({ variant, painted: 1 });
            expect(surface.seam).toBe(true);
            expect(surface.rowFill).toMatch(/transparent|rgba\(.*,\s*0\)$/);
          } finally {
            await page.close();
          }
        }
      });
    }
  }
});
