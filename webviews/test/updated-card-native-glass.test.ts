// l10n-allow-file: test fixtures.
// Leo 2026-10-30, on the sidebar's "cmux Updated!" card: "I don't like the non-glassness". The card
// is its own small page (surface.tsx, `#/surface/updated`) in a WebKit view over the sidebar, and a
// page's CSS glass sees nothing of the native sidebar under its view: its tint painted a flat fill,
// and in an opaque window the theme bootstrap's `html{background:... !important}` painted the whole
// page solid. The host now draws the sidebar cards' native glass under the page
// (SidebarUpdatedCardHost: CardSurfaceView), so the surface document paints only the words: the card
// has no `.ui-glass` (so the lens draws no wallpaper copy over the host's glass either), and the html
// has no fill, even against the bootstrap's !important rule.
//
// Leo 2026-11-07, on that card beside the composer: "the border styles, the glass intensity is
// different". The card now wears the composer's own material (ui/glass/composerMaterial.css), which
// the page paints: still translucent over the sidebar's glass (the composer's fill at the popover
// level's share, never near opaque), with the composer's edge and rim, and still no `.ui-glass`, no
// blur of its own in the sidebar and no html fill.
//
// Lawrence 2026-11-07, on that card's hover preview: "this ui transparency looks bad now". The open
// preview grows up over the sidebar's rows, and the page's blur never reaches them (the native rows
// are under the WebKit view, not in its document), so the translucent tint left every row legible
// through the list. The card then turned solid while open and dragged, and Leo 2026-11-08 asked for
// the glass back: "it turns from glass when it's unhovered into opaque when it does get hovered. I
// feel like we should be able to keep it as glass though, right?" The host now draws a native glass
// behind the page that frosts the rows (SidebarUpdatedCardHost.glass), so the card keeps the same
// translucent tint at rest, open, held and settling, in light, dark and over a see-through window,
// and its fill never swaps (the swap was the hover's flicker).
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
    "ui/glass/composerMaterial.css",
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
  const themes = {
    dark: `color-scheme:dark;${theme}`,
    light: "color-scheme:light;--cmux-surface-background:#ffffff;--cmux-surface-solid:#ffffff;--cmux-text:#24292f",
  };

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
     (window as any).mount = (glass: boolean | undefined, data: unknown, previewOpen?: boolean) => {
       const strings = createStrings(table);
       const root = createRoot(document.getElementById("root")!);
       const props: any = { data, strings, actions: { openChangelog() {}, dismiss() {} }, closeButton: false, previewMode: "above" };
       if (glass !== undefined) props.glass = glass;
       if (previewOpen !== undefined) props.previewOpen = previewOpen;
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

      async function open(
        surface: string | null,
        glassMode: string,
        glass: boolean | undefined,
        {
          previewOpen,
          look,
          seeThrough,
        }: { previewOpen?: boolean; look?: "light" | "dark"; seeThrough?: boolean } = {},
      ): Promise<Page> {
        const page = await browser.newPage({ viewport: { width: 300, height: 300 } });
        const attrs = `${surface ? ` data-surface="${surface}"` : ""} data-glass="${glassMode}"${seeThrough ? " data-cmux-see-through" : ""}`;
        const style = look ? themes[look] : theme;
        await page.setContent(
          `<!doctype html><html${attrs} style="${style}"><head><style>${css}</style><style id="cmux-theme">${bootstrap}</style></head>` +
            `<body><div id="root"></div></body></html>`,
        );
        await page.addScriptTag({ content: script });
        await page.evaluate(([g, d, p]) => (window as any).mount(g, d, p), [glass, data, previewOpen] as const);
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

      /** The alpha of a computed color ("rgba(r, g, b, a)", "color(srgb r g b / a)", or opaque). */
      const alpha = (color: string) => {
        const match = /\/\s*([\d.]+)\)$/.exec(color) ?? /rgba\([^)]*,\s*([\d.]+)\)$/.exec(color);
        return match ? Number(match[1]) : 1;
      };

      for (const glassMode of ["plain", "lens"]) {
        test(`the Updated surface paints the composer's translucent material and nothing around it (${glassMode})`, async () => {
          const page = await open("updated", glassMode, false);
          const got = await paint(page);
          expect(got.glassInDocument).toBe(0);
          expect(got.html).toBe("rgba(0, 0, 0, 0)");
          expect(got.backdrop).toBe("none");
          expect(alpha(got.card)).toBeGreaterThan(0.3);
          expect(alpha(got.card)).toBeLessThan(0.9);
          expect(got.shadow).not.toBe("none");
          // The shipped title line is "Updated to …" alone; What's New leads the open preview (8d5626228).
          expect(await page.locator(".wn-card").innerText()).toContain("Updated to");
          await page.close();
        });
      }

      for (const look of ["light", "dark"] as const) {
        for (const seeThrough of [false, true]) {
          const where = `${look}${seeThrough ? ", see-through window" : ""}`;
          test(`the open hover preview keeps the card's translucent material (${where})`, async () => {
            const resting = await open("updated", "plain", false, { previewOpen: false, look, seeThrough });
            const rest = (await paint(resting)).card;
            await resting.close();
            const page = await open("updated", "plain", false, { previewOpen: true, look, seeThrough });
            await page.waitForSelector('.wn-updated[data-preview="open"]');
            const got = await paint(page);
            // The host's native glass frosts the rows under the WebKit view; the page paints only the tint.
            expect(got.backdrop).toBe("none");
            expect(got.card).toBe(rest);
            expect(alpha(got.card)).toBeLessThan(0.9);
            expect(await page.locator(".wn-preview").innerText()).toContain("Tables scroll");
            await page.close();
          });
          test(`the resting card keeps the composer's translucent material (${where})`, async () => {
            const page = await open("updated", "plain", false, { previewOpen: false, look, seeThrough });
            expect(alpha((await paint(page)).card)).toBeLessThan(0.9);
            await page.close();
          });
        }
      }

      for (const look of ["light", "dark"] as const) {
        for (const seeThrough of [false, true]) {
          const where = `${look}${seeThrough ? ", see-through window" : ""}`;
          test(`the dragged card keeps the card's translucent material, through its settle (${where})`, async () => {
            const page = await open("updated", "plain", false, { previewOpen: false, look, seeThrough });
            const got = await page.evaluate(() => {
              const card = document.querySelector<HTMLElement>(".wn-card")!;
              const fill = () => getComputedStyle(card).backgroundColor;
              const resting = fill();
              card.dataset.dragging = "";
              const held = fill();
              // Let go: the host springs the card back over the rows to its rest.
              delete card.dataset.dragging;
              const settling = fill();
              return { resting, held, settling };
            });
            expect(alpha(got.resting)).toBeLessThan(0.9);
            expect(got.held).toBe(got.resting);
            expect(got.settling).toBe(got.resting);
            await page.close();
          });
        }
      }

      test("a card with its own page glass (the gallery over a wallpaper) keeps the tint, open or held", async () => {
        // Its blur frosts what is under it in its own document: the solid surface is only for the
        // sidebar's card, whose page has no glass and nothing under it the blur could read.
        const page = await open("updated", "plain", true, { previewOpen: true, look: "dark" });
        await page.waitForSelector('.wn-updated[data-preview="open"]');
        const got = await page.evaluate(() => {
          const card = document.querySelector<HTMLElement>(".wn-card")!;
          const open = getComputedStyle(card).backgroundColor;
          card.dataset.dragging = "";
          const held = getComputedStyle(card).backgroundColor;
          return { open, held };
        });
        expect(alpha(got.open)).toBeLessThan(0.9);
        expect(alpha(got.held)).toBeLessThan(0.9);
        await page.close();
      });
    });
  }
});
