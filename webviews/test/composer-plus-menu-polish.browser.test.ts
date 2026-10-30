// cmux-web-test-timeout: 240
// The composer's + menu (PaletteMenu) in the real gallery stage, laid out by Chromium, held to
// the Claude desktop + menu it is compared with (polish audit, 2026-10-29; Leo, 2026-10-28: "I
// feel like you guys could be doing more audits of the app. Like there's some amount of, like,
// satisfying and pretty stuff that can happen that we're not quite taking full advantage of."):
// - its groups are split by the shared menu separator (`.ui-separator`) at a menu's group
//   spacing, not by about 40px of empty space;
// - a list that scrolls fades at the edge rows pass under (`useScrollEdges`, the pane's shared
//   scroll-edge fade), and the search field above it never fades;
// - the search field draws no ring, focused or not (design/composer.md: no focus ring on the
//   composer's controls);
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
  }, 140_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /** The balanced state (four groups) with its menu open, in a pane `height` tall. */
  async function opened(height: number): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 520, height } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: "balanced", reducedMotion: "true" })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
    expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
    // The variant's play opens the menu before the stage reports ready (gallery/frame/main.ts).
    if (!(await page.$(".acpmux-palette-menu"))) await page.click(".acpmux-picker-button");
    await page.waitForSelector(".acpmux-palette-menu .acpmux-menu-item");
    return page;
  }

  test("groups are split by the shared menu separator at a menu's group spacing", async () => {
    const page = await opened(900);
    const gaps = await page.$$eval(".acpmux-palette-menu .acpmux-menu-section", (sections) =>
      sections.slice(1).map((section, index) => {
        const previous = sections[index]!.querySelectorAll(".acpmux-menu-item");
        const lastRow = previous[previous.length - 1]!.getBoundingClientRect();
        const header = section.querySelector(".acpmux-menu-header")!.getBoundingClientRect();
        // The separator between the two groups: the element right before this section, or the
        // section's own first child.
        const candidates = [section.previousElementSibling, section.firstElementChild];
        const separator = candidates.find((node) => node?.matches(".ui-separator, [role=separator]"));
        const line = separator?.getBoundingClientRect();
        const css = separator ? getComputedStyle(separator) : undefined;
        return {
          empty: Math.round(header.top - lastRow.bottom),
          separator: line
            ? {
                height: line.height,
                between: line.top >= lastRow.bottom - 0.5 && line.bottom <= header.top + 0.5,
                background: css!.backgroundColor,
              }
            : null,
        };
      }),
    );
    console.log(`composer-plus-menu-polish: group gaps ${JSON.stringify(gaps)}`);
    expect(gaps.length).toBe(3);
    for (const gap of gaps) {
      expect(gap.separator).not.toBeNull();
      expect(gap.separator!.between).toBe(true);
      expect(gap.separator!.height).toBeGreaterThan(0);
      expect(gap.separator!.background).not.toMatch(/^(transparent|rgba\(0, 0, 0, 0\))$/);
      // A menu's group spacing: the separator's own margins around its hairline, no more.
      expect(gap.empty).toBeLessThanOrEqual(12);
    }
    await page.close();
  });

  test("the list fades at the edges rows scroll under, and the search field never fades", async () => {
    const page = await opened(320);
    const state = () =>
      page.$eval(".acpmux-palette-menu", (menu) => {
        const list = menu.querySelector<HTMLElement>("[role=listbox]")!;
        const input = menu.querySelector("input")!;
        const masked = (node: Element | null): boolean =>
          !!node && (getComputedStyle(node).maskImage !== "none" || masked(node.parentElement));
        return {
          scrolls: list.scrollHeight > list.clientHeight + 1,
          top: list.hasAttribute("data-fade-top"),
          bottom: list.hasAttribute("data-fade-bottom"),
          mask: getComputedStyle(list).maskImage,
          searchMasked: masked(input),
        };
      });
    const rest = await state();
    console.log(`composer-plus-menu-polish: at rest ${JSON.stringify(rest)}`);
    expect(rest.scrolls).toBe(true);
    expect(rest.bottom).toBe(true);
    expect(rest.top).toBe(false);
    expect(rest.mask).not.toBe("none");
    expect(rest.searchMasked).toBe(false);
    await page.$eval(".acpmux-palette-menu [role=listbox]", (list) => {
      list.scrollTop = list.scrollHeight;
    });
    await page.waitForFunction(() =>
      document.querySelector(".acpmux-palette-menu [role=listbox]")?.hasAttribute("data-fade-top"),
    );
    const end = await state();
    expect(end.top).toBe(true);
    expect(end.bottom).toBe(false);
    expect(end.searchMasked).toBe(false);
    await page.close();
  });

  test("the search field draws no ring, focused by the open or by the keyboard", async () => {
    const page = await opened(900);
    const ring = () =>
      page.$eval(".acpmux-palette-menu input", (input) => {
        const css = getComputedStyle(input);
        return {
          focused: document.activeElement === input,
          boxShadow: css.boxShadow,
          outline: css.outlineStyle === "none" ? "none" : `${css.outlineWidth} ${css.outlineStyle}`,
        };
      });
    const rest = await ring();
    console.log(`composer-plus-menu-polish: search field ${JSON.stringify(rest)}`);
    expect(rest.focused).toBe(true);
    expect(rest.boxShadow).toBe("none");
    expect(rest.outline).toBe("none");
    // Typing makes the focus keyboard focus (:focus-visible); still no ring.
    await page.keyboard.type("br");
    expect(await ring()).toEqual({ focused: true, boxShadow: "none", outline: "none" });
    await page.close();
  });

  test("the menu opens in one frame, with no fade-in", async () => {
    const page = await opened(900);
    const motion = await page.$eval(".acpmux-palette-menu", (menu) => ({
      opacity: getComputedStyle(menu).opacity,
      animations: menu.getAnimations({ subtree: true }).length,
    }));
    expect(motion).toEqual({ opacity: "1", animations: 0 });
    await page.close();
  });
});
