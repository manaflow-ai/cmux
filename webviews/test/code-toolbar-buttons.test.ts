// cmux-web-test-timeout: 300
// A code card's, an edit diff's, a tool output's and a reply table's corner buttons are bare glyphs,
// as a reply's Copy is: no tile behind the pair and no fill on any button at rest; only the button
// under the pointer takes the hover fill (Leo 2026-11-07, on Wrap and Copy on opaque tiles with a
// gap: "why not just have it similar to how we have the, you know, the copy button or whatever,
// where it doesn't really have anything until you highlight over it"). The buttons sit side by side
// with no gap, as the reply row's do, and hit targets stay the same size.
//
// It renders `agent-pane.code-toolbar-buttons` on the gallery stage in Chromium, dark and light.
// CI fails the file when it cannot launch (requireBrowserLane). Locally:
// CMUX_BROWSER_TESTS=1 bun test test/code-toolbar-buttons.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("code-toolbar-buttons.test.ts", async () => {
  const ENTRY = "agent-pane.code-toolbar-buttons";
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("code toolbar buttons", () => test("chromium", () => {}));
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
    const page = await browser!.newPage({ viewport: { width: 680, height: 420 } });
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

  /** Each button's fill and size, and whether anything between it and its block paints a plate. */
  const looks = (page: Page, block: string, buttons: string) =>
    page.evaluate(
      ({ block, buttons }) => {
        const clear = (color: string) => color === "transparent" || /rgba\(.*,\s*0\)$/.test(color);
        const painted = (element: Element) => {
          const style = getComputedStyle(element);
          return !clear(style.backgroundColor) || style.backgroundImage !== "none";
        };
        return [...document.querySelectorAll(buttons)].map((button) => {
          const plate: string[] = [];
          for (let node = button.parentElement; node && !node.matches(block); node = node.parentElement)
            if (painted(node) || getComputedStyle(node).backdropFilter !== "none") plate.push(node.className);
          const box = button.getBoundingClientRect();
          return {
            name: button.getAttribute("aria-label") ?? button.textContent,
            filled: painted(button),
            plate,
            left: Math.round(box.left),
            right: Math.round(box.right),
            width: Math.round(box.width),
            height: Math.round(box.height),
          };
        });
      },
      { block, buttons },
    );

  const SURFACES = [
    {
      surface: "code",
      block: ".cv-codeblock",
      // The first card is an unlabeled highlighted one: Wrap and Copy in its corner.
      buttons: ".cv-codeblock:first-child .cv-codeblock__actions > button",
      size: 26,
      min: 2,
    },
    {
      surface: "diff",
      block: ".cv-edit-diff",
      buttons: ".cv-edit-diff__header button",
      size: 26,
      min: 2,
    },
    {
      surface: "output",
      block: ".cv-shell",
      buttons: ".cv-shell__actions > button",
      size: 26,
      min: 2,
    },
    {
      surface: "table",
      block: ".cv-table-block",
      buttons: ".cv-table-tools > button",
      size: 24,
      min: 2,
    },
  ] as const;

  for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
    for (const { surface, block, buttons, size, min } of SURFACES)
      test(`${theme}, ${surface}: bare glyphs at rest, a fill only on the hovered button`, async () => {
        const page = await open(surface, theme);
        // Under the pointer the block reveals its buttons; none of them is filled yet.
        await page.locator(block).first().hover();
        await eased(page);
        const rest = await looks(page, block, buttons);
        expect(rest.length, "the block shows its buttons").toBeGreaterThanOrEqual(min);
        for (const button of rest) {
          expect({ name: button.name, filled: button.filled }, "no fill at rest").toEqual({
            name: button.name,
            filled: false,
          });
          expect({ name: button.name, plate: button.plate }, "no tile behind the buttons").toEqual({
            name: button.name,
            plate: [],
          });
          expect([button.width, button.height], `${button.name}: the hit target keeps its size`).toEqual([size, size]);
        }

        // Side by side, as a reply's Copy row has them: no gap between neighbours.
        for (let i = 1; i < rest.length; i++)
          expect(rest[i]!.left - rest[i - 1]!.right, `no gap before ${rest[i]!.name}`).toBe(0);

        // Hover the last button: it alone takes the fill.
        const target = page.locator(buttons).last();
        await target.hover();
        await eased(page);
        const hovered = await looks(page, block, buttons);
        const last = hovered.length - 1;
        expect(hovered[last]!.filled, "the hovered button fills").toBe(true);
        for (const button of hovered.slice(0, last))
          expect({ name: button.name, filled: button.filled }, "its neighbours stay bare").toEqual({
            name: button.name,
            filled: false,
          });
        await page.close();
      });
});
