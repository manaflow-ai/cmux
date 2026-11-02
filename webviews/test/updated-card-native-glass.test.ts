// l10n-allow-file: test fixtures.
// Leo 2026-10-30, on the sidebar's "cmux Updated!" card: "I don't like the non-glassness". The card
// is its own small page (surface.tsx, `#/surface/updated`) in a WebKit view over the sidebar, and a
// page's CSS glass sees nothing of the native sidebar under its view: its tint painted a flat fill,
// and in an opaque window the theme bootstrap's `html{background:... !important}` painted the whole
// page solid. The host now draws the sidebar cards' native glass under the page
// (SidebarUpdatedCardHost: CardSurfaceView), so the surface document paints only the words: the card
// has no `.ui-glass` (so the lens draws no wallpaper copy over the host's glass either), and the html
// has no fill, even against the bootstrap's !important rule. The card elsewhere (the gallery) keeps
// its CSS glass.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("updated-card-native-glass.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");

  test("the sidebar's surface renders the card without its own glass", () => {
    const surface = fs.readFileSync(path.join(source, "pages/changelog/surface.tsx"), "utf8");
    expect(surface).toMatch(/<UpdatedCard[^>]*glass=\{false\}/s);
    // And no lens over the host's glass (glass-lens.test.ts checks the attribute stops the lens).
    expect(surface).toMatch(/kind === "updated"\) document\.documentElement\.setAttribute\(NATIVE_GLASS_ATTRIBUTE/);
  });

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
  // WebTheme.bootstrapScript's page background rule, after the page's own sheets, with an opaque
  // window's page color (WebTheme: the surface at alpha 1 when panes paint the background).
  const bootstrap = "html{background:var(--cmux-surface-background) !important}body{background:transparent !important}";
  const theme = "--cmux-surface-background:#1e1e1e;--cmux-surface-solid:#1e1e1e;--cmux-text:#ddd";

  // Inside webviews/ so the bundle resolves react from its node_modules.
  const dir = fs.mkdtempSync(path.join(import.meta.dir, ".updated-card-glass-"));
  const entry = path.join(dir, "entry.tsx");
  fs.writeFileSync(
    entry,
    `import { createElement } from "react";
     import { flushSync } from "react-dom";
     import { createRoot } from "react-dom/client";
     import { UpdatedCard } from ${JSON.stringify(path.join(source, "pages/changelog/UpdateSurfaces.tsx"))};
     import { createStrings } from ${JSON.stringify(path.join(source, "pages/shared/i18n.ts"))};
     import table from ${JSON.stringify(path.join(source, "pages/changelog/generated/strings.json"))};
     (window as any).mount = (glass: boolean | undefined, data: unknown) => {
       const strings = createStrings(table);
       const root = createRoot(document.getElementById("root")!);
       const props: any = { data, strings, actions: { openChangelog() {}, dismiss() {} }, closeButton: false };
       if (glass !== undefined) props.glass = glass;
       flushSync(() => root.render(createElement(UpdatedCard, props)));
     };`,
  );
  const built = await Bun.build({ entrypoints: [entry], target: "browser" });
  fs.rmSync(dir, { recursive: true, force: true });
  if (!built.success) throw new Error(built.logs.join("\n"));
  const script = await built.outputs[0].text();

  const data = {
    version: "1.0.0-nightly.3845050428001",
    build: "3845050428001",
    fromVersion: "1.0.0-nightly.3801702344901",
    fromBuild: "3801702344901",
    date: "2026-10-19",
    source: "whatsNew",
    language: "en",
    items: [{ id: "scroll", title: "Tables scroll", summary: null, category: "improved" }],
    moreCount: 0,
    changelog: { from: "1.0.0-nightly.3801702344901", to: "1.0.0-nightly.3845050428001" },
  };

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

      async function open(surface: string | null, glassMode: string, glass: boolean | undefined): Promise<Page> {
        const page = await browser.newPage({ viewport: { width: 300, height: 300 } });
        const attrs = `${surface ? ` data-surface="${surface}"` : ""} data-glass="${glassMode}"`;
        await page.setContent(
          `<!doctype html><html${attrs} style="${theme}"><head><style>${css}</style><style id="cmux-theme">${bootstrap}</style></head>` +
            `<body><div id="root"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        await page.evaluate(([g, d]) => (window as any).mount(g, d), [glass, data] as const);
        return page;
      }

      const paint = (page: Page) =>
        page.evaluate(() => {
          const card = getComputedStyle(document.querySelector(".wn-card")!);
          const style = card as unknown as Record<string, string>;
          return {
            glassInDocument: document.getElementsByClassName("ui-glass").length,
            html: getComputedStyle(document.documentElement).backgroundColor,
            card: card.backgroundColor,
            shadow: card.boxShadow,
            backdrop: style.backdropFilter || style.webkitBackdropFilter || "none",
          };
        });

      for (const glassMode of ["plain", "lens"]) {
        test(`the Updated surface paints nothing under or around the words (${glassMode})`, async () => {
          const page = await open("updated", glassMode, false);
          expect(await paint(page)).toEqual({
            glassInDocument: 0,
            html: "rgba(0, 0, 0, 0)",
            card: "rgba(0, 0, 0, 0)",
            shadow: "none",
            backdrop: "none",
          });
          expect(await page.locator(".wn-card").innerText()).toContain("What's New");
          await page.close();
        });
      }

      test("the card elsewhere keeps its CSS glass", async () => {
        const page = await open(null, "plain", undefined);
        const { glassInDocument, card, shadow } = await paint(page);
        expect(glassInDocument).toBe(1);
        expect(card).not.toBe("rgba(0, 0, 0, 0)");
        expect(shadow).not.toBe("none");
        await page.close();
      });
    });
  }
});
