// cmux-web-test-timeout: 240
// The composer's + menus in the real gallery stages, laid out by Chromium: the searchable palette
// (PaletteMenu, which #26616 puts under the composer's +) and the + the composer draws today
// (Picker, `.acpmux-composer-plus`). Both are held to
// the Claude desktop + menu it is compared with (polish audit, 2026-10-29; Leo, 2026-10-28: "I
// feel like you guys could be doing more audits of the app. Like there's some amount of, like,
// satisfying and pretty stuff that can happen that we're not quite taking full advantage of."):
// - groups are split by the pane's menu hairline (the palette draws the shared `.ui-separator`)
//   at a menu's group spacing, not by about 40px of empty space;
// - a list that scrolls fades at the edge rows pass under (`useScrollEdges`, the pane's shared
//   scroll-edge fade), and the search field above it never fades;
// - the palette's search field draws no ring while focused (design/composer.md: no focus ring
//   on the composer's controls);
// - the menu still opens in one frame, with no fade-in (rulebook: menus open on the click).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("composer-plus-menu-polish.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-plus-menu-polish: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer plus menu polish", () => test("chromium", () => {}));
    return;
  }
  const ENTRY = "agent-pane.composer-plus-menu";
  /** The two + menus: a gallery state whose play opens it, and the popup it draws. */
  const MENUS = {
    palette: { entry: ENTRY, variant: "balanced", popup: ".acpmux-palette-menu", width: 520 },
    picker: {
      entry: "agent-pane.composer",
      variant: "add-menu",
      popup: ".acpmux-composer-plus .acpmux-menu",
      width: 400,
    },
  } as const;
  type Menu = keyof typeof MENUS;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: "balanced" } });
    await warmGalleryFrame(vite, MENUS.picker.entry, { browser, params: { variant: MENUS.picker.variant } });
  }, 200_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** A + menu's gallery state with the menu open, in a pane `height` tall. */
  async function opened(menu: Menu, height: number): Promise<Page> {
    const { entry, variant, popup, width } = MENUS[menu];
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width, height } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, reducedMotion: "true" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
    // The variant's play opens the menu before the stage reports ready (gallery/frame/main.ts).
    await page.waitForSelector(`${popup} .acpmux-menu-item`);
    return page;
  }

  /** Each pair of groups: the blank between them and the hairline that splits them, if any. */
  function groupGaps(page: Page, menu: Menu) {
    return page.$$eval(`${MENUS[menu].popup} .acpmux-menu-section`, (sections) =>
      sections.slice(1).map((section, index) => {
        const previous = sections[index]!.querySelectorAll(".acpmux-menu-item");
        const lastRow = previous[previous.length - 1]!.getBoundingClientRect();
        const next = section.firstElementChild!.getBoundingClientRect();
        const painted = (css: CSSStyleDeclaration) =>
          Number.parseFloat(css.borderTopWidth) > 0 && css.borderTopStyle !== "none"
            ? css.borderTopColor
            : css.backgroundColor;
        // The split: a separator element right before the group (the palette's `.ui-separator`),
        // or the group's own top border (the Picker's).
        const element = section.previousElementSibling?.matches(".ui-separator, [role=separator]")
          ? section.previousElementSibling
          : null;
        const own = getComputedStyle(section);
        const box = element?.getBoundingClientRect() ?? section.getBoundingClientRect();
        const width = element ? box.height : own.borderTopStyle === "none" ? 0 : Number.parseFloat(own.borderTopWidth);
        return {
          empty: Math.round(next.top - lastRow.bottom),
          separator:
            width > 0
              ? {
                  height: width,
                  between: box.top >= lastRow.bottom - 0.5 && box.top + width <= next.top + 0.5,
                  paint: painted(element ? getComputedStyle(element) : own),
                }
              : null,
        };
      }),
    );
  }

  for (const menu of ["palette", "picker"] as const)
    test(`the ${menu} +: groups are split by the menu hairline at a menu's group spacing`, async () => {
      const page = await opened(menu, 900);
      const gaps = await groupGaps(page, menu);
      console.log(`composer-plus-menu-polish: ${menu} group gaps ${JSON.stringify(gaps)}`);
      expect(gaps.length).toBeGreaterThan(0);
      for (const gap of gaps) {
        expect(gap.separator).not.toBeNull();
        expect(gap.separator!.between).toBe(true);
        expect(gap.separator!.paint).not.toMatch(/^(transparent|rgba\(0, 0, 0, 0\))$/);
        // A menu's group spacing: the hairline's own margins, no more.
        expect(gap.empty).toBeLessThanOrEqual(12);
      }
      await page.close();
    });

  test("the palette has a separator between each of its four groups", async () => {
    const page = await opened("palette", 900);
    expect(await page.$$eval(".acpmux-palette-menu .ui-separator", (nodes) => nodes.length)).toBe(3);
    await page.close();
  });

  // A pane short enough that each menu's rows scroll: the palette's list under its search field,
  // the Picker's popup itself. The + popup takes the room the pane has above or below + (up to
  // 520px, styles.css), not half the window, so its rows scroll only once that room runs out.
  const SHORT: Record<Menu, number> = { palette: 320, picker: 320 };
  for (const menu of ["palette", "picker"] as const)
    test(`the ${menu} +: rows fade at the edges they scroll under, and a search field never fades`, async () => {
      const page = await opened(menu, SHORT[menu]);
      const state = () =>
        page.$eval(MENUS[menu].popup, (popup) => {
          const scrolls = (node: Element) => node.scrollHeight > node.clientHeight + 1;
          // Whichever box scrolls the rows: the list under the search field, or the popup itself.
          const list = popup.querySelector<HTMLElement>("[role=listbox]");
          const scroller = list && scrolls(list) ? list : popup;
          scroller.setAttribute("data-test-scroller", "");
          const input = popup.querySelector("input");
          const masked = (node: Element | null): boolean =>
            !!node && (getComputedStyle(node).maskImage !== "none" || masked(node.parentElement));
          return {
            scroller: scroller === popup ? "popup" : "list",
            scrolls: scrolls(scroller),
            top: scroller.hasAttribute("data-fade-top"),
            bottom: scroller.hasAttribute("data-fade-bottom"),
            mask: getComputedStyle(scroller).maskImage,
            searchMasked: input ? masked(input) : false,
          };
        });
      const rest = await state();
      console.log(`composer-plus-menu-polish: ${menu} at rest ${JSON.stringify(rest)}`);
      expect(rest.scrolls).toBe(true);
      expect(rest.bottom).toBe(true);
      expect(rest.top).toBe(false);
      expect(rest.mask).not.toBe("none");
      expect(rest.searchMasked).toBe(false);
      await page.$eval("[data-test-scroller]", (scroller) => {
        scroller.scrollTop = scroller.scrollHeight;
      });
      await page.waitForFunction(() => document.querySelector("[data-test-scroller]")?.hasAttribute("data-fade-top"));
      const end = await state();
      expect(end.top).toBe(true);
      expect(end.bottom).toBe(false);
      expect(end.searchMasked).toBe(false);
      await page.close();
    });

  test("the search field draws no ring while it has the focus", async () => {
    const page = await opened("palette", 900);
    // WebKit (the app) leaves the focus in the field the menu focuses on open: a clicked button
    // takes none there. Chromium hands it to the clicked + button, so the test puts it back.
    await page.focus(".acpmux-palette-menu input");
    // Read the settled style: a focus transition starts from "none" (the old ring read as a
    // transparent 0px shadow on its first frame).
    const settled = () =>
      page.waitForFunction(() => document.querySelector(".acpmux-palette-menu input")?.getAnimations().length === 0);
    const ring = () =>
      page.$eval(".acpmux-palette-menu input", (input) => {
        const css = getComputedStyle(input);
        return {
          focused: document.activeElement === input,
          boxShadow: css.boxShadow,
          outline: css.outlineStyle === "none" ? "none" : `${css.outlineWidth} ${css.outlineStyle}`,
        };
      });
    await settled();
    const rest = await ring();
    console.log(`composer-plus-menu-polish: search field ${JSON.stringify(rest)}`);
    expect(rest.focused).toBe(true);
    expect(rest.boxShadow).toBe("none");
    expect(rest.outline).toBe("none");
    // Typing filters and keeps the focus there (:focus-visible); still no ring.
    await page.keyboard.type("br");
    await settled();
    expect(await ring()).toEqual({ focused: true, boxShadow: "none", outline: "none" });
    await page.close();
  });

  for (const menu of ["palette", "picker"] as const)
    test(`the ${menu} + opens in one frame, with no fade-in`, async () => {
      const page = await opened(menu, 900);
      // The popup's own animations: an open fade, scale or slide would run on it.
      const motion = await page.$eval(MENUS[menu].popup, (popup) => ({
        opacity: getComputedStyle(popup).opacity,
        animations: popup.getAnimations().length,
      }));
      expect(motion).toEqual({ opacity: "1", animations: 0 });
      await page.close();
    });
});
