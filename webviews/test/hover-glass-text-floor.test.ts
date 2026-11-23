// Text on glass keeps its floor (glass.css "TEXT ON GLASS KEEPS ITS FLOOR"; Leo, 2026-11-20: "WHERE IS
// THE GLASS EVERYWHERE ALL THESE STUPID F***ING HOVER TOOLTIPS AND HOVER PREVIEW SHIT"; hq#15378: the
// composer's Model menu let the chat read through its list). In a see-through Chromium page a popup,
// tooltip or hover card that nothing blurs under (over the composer, or before the App draws its glass)
// lays the theme surface under its tint at no less than --surface-text-min, whatever the
// chromium-glass-underlay arm; one the page blurs under (data-glass-over) lays none; in-page glass
// (the composer) keeps the arm's underlay. Off (Reduce Transparency) every one of them is solid.
//
// Before: the menu's underlay was the arm's (70%, 0% on the none arm), so the chat read through it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("hover-glass-text-floor.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/glass/glass.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");
  const floor = Number(/--surface-text-min:\s*(\d+(?:\.\d+)?)%/.exec(css)?.[1]);

  const SURFACES = {
    menu: "ui-popup ui-glass",
    tooltip: "ui-tooltip ui-glass",
    card: "ui-tooltip ui-card ui-glass",
    preview: "ui-card ui-glass",
    composer: "ui-glass ui-glass-floats",
  } as const;

  const html = (arm: string, root = "") =>
    `<!doctype html><html data-cmux-see-through data-glass="plain" data-glass-underlay="${arm}" ${root}
       style="--cmux-surface-background:transparent;--cmux-surface-solid:rgb(30,30,30);background:transparent">
     <head><style>${css} body { margin: 0 } div { width: 120px; height: 40px }</style></head><body>
     ${Object.entries(SURFACES)
       .map(([id, classes]) => `<div id="${id}" class="${classes}">Text</div>`)
       .join("")}
     <div id="blurred" class="ui-popup ui-glass" data-glass-over>Text</div>
     </body></html>`;

  async function open(browser: Browser, arm: string, root?: string): Promise<Page> {
    const page = await browser.newPage({ viewport: { width: 400, height: 400 } });
    await page.setContent(html(arm, root));
    return page;
  }

  /** A computed color's alpha, 0 to 1: `rgba(r, g, b, a)`, `rgb(r g b / a)` or `color(srgb r g b / a)`. */
  const alphaOf = (fill: string) => {
    const inner = /\(([^)]*)\)\s*$/.exec(fill)?.[1] ?? "";
    if (inner.includes("/"))
      return Number(inner.split("/")[1]!.trim().replace(/%$/, "")) / (inner.trim().endsWith("%") ? 100 : 1);
    const commas = inner.split(",");
    return commas.length === 4 ? Number(commas[3]) : 1;
  };

  /** The alpha of the fill under the surface's tint (the color layer of its background), 0 to 1. */
  const underlay = async (page: Page, id: string) =>
    alphaOf(await page.evaluate((target) => getComputedStyle(document.getElementById(target)!).backgroundColor, id));

  describe("text on glass keeps its floor in chromium", () => {
    let browser: Browser;
    beforeAll(async () => {
      browser = await chromium.launch({ headless: true });
    });
    afterAll(async () => browser?.close());

    test("--surface-text-min is the legible floor", () => {
      expect(floor).toBeGreaterThanOrEqual(90);
    });

    for (const arm of ["none", "light", "medium", "heavy"]) {
      test(`${arm} arm: a menu, tooltip and hover card lay at least the floor under their text`, async () => {
        const page = await open(browser, arm);
        for (const id of ["menu", "tooltip", "card", "preview"]) {
          expect(await underlay(page, id), `${id} underlay`).toBeGreaterThanOrEqual(floor / 100 - 0.005);
        }
        // The page blurs under this one: no underlay, the blur hides what is under it.
        expect(await underlay(page, "blurred")).toBe(0);
        // In-page glass (the composer) keeps the arm's underlay: still glass, never at the floor.
        expect(await underlay(page, "composer")).toBeLessThan(0.9);
        await page.close();
      });
    }

    test("off (Reduce Transparency): every hover surface is solid", async () => {
      const page = await open(browser, "medium", "data-reduce-transparency");
      for (const id of ["menu", "tooltip", "card", "preview"]) {
        const style = await page.evaluate((target) => {
          const computed = getComputedStyle(document.getElementById(target)!);
          return { image: computed.backgroundImage, color: computed.backgroundColor, blur: computed.backdropFilter };
        }, id);
        expect(style.image, `${id} image`).toBe("none");
        expect(style.blur, `${id} blur`).toBe("none");
        expect(alphaOf(style.color), `${id} fill ${style.color}`).toBe(1);
      }
      await page.close();
    });
  });
});
