// Leo 2026-10-30, on the sidebar's "cmux Updated!" card: "I don't like the non-glassness". The card
// is its own small page (surface.tsx, `#/surface/updated`) in a WebKit view over the sidebar, and a
// page's CSS glass sees nothing of the native sidebar under its view: its tint painted a flat fill,
// and in an opaque window the theme bootstrap's `html{background:... !important}` painted the whole
// page solid. The host now draws the sidebar cards' native glass under the page
// (SidebarUpdatedCardHost: CardSurfaceView), so the surface document paints only the words: no html
// fill (even against the bootstrap's !important rule) and no fill, blur or rim on the card. The same
// card outside the surface document (the gallery) keeps its CSS glass.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-native-glass.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "ui/glass/glass.css",
    "pages/shared/pageBase.css",
    "pages/changelog/updateSurfaces.css",
    "pages/changelog/surface.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n")
    .replace(/^@import .*$/gm, "");
  // WebTheme.bootstrapScript's page background rule, injected after the page's own sheets, with an
  // opaque window's page color (WebTheme: the surface at alpha 1 when panes paint the background).
  const bootstrap = "html{background:var(--cmux-surface-background) !important}body{background:transparent !important}";
  const theme = "--cmux-surface-background:#1e1e1e;--cmux-surface-solid:#1e1e1e;--cmux-text:#ddd";

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    describe(name, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      async function open(surface: string | null, glass: string): Promise<Page> {
        const page = await browser.newPage({ viewport: { width: 300, height: 200 } });
        const attrs = `${surface ? ` data-surface="${surface}"` : ""} data-glass="${glass}"`;
        await page.setContent(
          `<!doctype html><html${attrs} style="${theme}"><head><style>${css}</style><style id="cmux-theme">${bootstrap}</style></head>` +
            `<body><div id="root"><section class="ui-glass wn-card"><div class="wn-card-eyebrow">Nightly</div></section></div></body></html>`,
        );
        return page;
      }

      const paint = (page: Page) =>
        page.evaluate(() => {
          const card = getComputedStyle(document.querySelector(".wn-card")!);
          return {
            html: getComputedStyle(document.documentElement).backgroundColor,
            card: card.backgroundColor,
            image: card.backgroundImage,
            shadow: card.boxShadow,
            backdrop: card.backdropFilter || (card as unknown as Record<string, string>).webkitBackdropFilter || "none",
          };
        });

      for (const glass of ["plain", "lens"]) {
        test(`the Updated surface paints no fill of its own (${glass})`, async () => {
          const page = await open("updated", glass);
          expect(await paint(page)).toEqual({
            html: "rgba(0, 0, 0, 0)",
            card: "rgba(0, 0, 0, 0)",
            image: "none",
            shadow: "none",
            backdrop: "none",
          });
          await page.close();
        });
      }

      test("the card outside the surface document keeps its CSS glass", async () => {
        const page = await open(null, "plain");
        const { card, shadow } = await paint(page);
        expect(card).not.toBe("rgba(0, 0, 0, 0)");
        expect(shadow).not.toBe("none");
        await page.close();
      });
    });
  }
});
