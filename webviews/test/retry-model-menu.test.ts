// cmux-web-test-timeout: 300
// Retry's model menu (RetryModelMenu.tsx) draws as the composer's model menu does (Lawrence and Leo
// 2026-10-20: a raw list, no insets, the check against the name, a huge font): the composer model
// menu's text size and row height (#26071 matched them to the composer's text), rows inset from
// the menu's edge, a caption header, the check in its own column clear of every label, which all
// start at one x, and More models last. Dark and light themes.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/retry-model-menu.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("retry-model-menu.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`retry model menu: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("retry model menu", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (width: number, theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame("agent-pane.retry-model-menu", { variant: "closed", frame: "component", width, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, "agent-pane.retry-model-menu", {
      browser: [...browsers.values()][0],
      params: { variant: "closed" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /** Resolves once nothing on the page is easing: no transition or animation left to run (a
   *  looping one never ends). */
  const eased = (page: Page) =>
    page.waitForFunction(() =>
      document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    );
  const open = async (engine: string, width: number, theme: string): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 600 } });
    await page.goto(stageURL(width, theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    const box = (await page.locator('button[aria-label="Retry with another model"]').boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.up();
    await page.locator('[role="menu"] [role="menuitemradio"][aria-checked="true"]').waitFor();
    // The menu has finished opening.
    await eased(page);
    return page;
  };

  for (const [engine] of engines)
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
      test(`${engine}, ${theme}: Retry's model menu has the native menu's font, insets, sections and check column`, async () => {
        const page = await open(engine, 560, theme);
        const geometry = await page.evaluate(() => {
          const menu = document.querySelector<HTMLElement>('[role="menu"]')!;
          const menuBox = menu.getBoundingClientRect();
          const rows = [...menu.querySelectorAll<HTMLElement>('[role="menuitemradio"]')].map((row) => {
            const box = row.getBoundingClientRect();
            const check = row.querySelector(".ui-menu-check")!;
            const range = document.createRange();
            // The row's name: its text without the check's.
            const label = [...row.querySelectorAll("*")].find(
              (element) =>
                element !== check &&
                !check.contains(element) &&
                element.textContent?.trim() &&
                !element.children.length,
            )!;
            range.selectNodeContents(label);
            const text = range.getBoundingClientRect();
            const mark = check.getBoundingClientRect();
            // A model's detail ("1M context"): in the row, after its name, on the name's line.
            const value = row.querySelector(".acpmux-quick-value")?.getBoundingClientRect();
            return {
              name: label.textContent,
              detail: value
                ? {
                    inRow: value.left >= text.right && value.right <= box.right + 0.5,
                    inMenu: value.right <= menuBox.right + 0.5,
                    sameLine: Math.abs(value.top + value.height / 2 - (text.top + text.height / 2)) <= 2,
                  }
                : null,
              checked: row.getAttribute("aria-checked") === "true",
              fontSize: parseFloat(getComputedStyle(label).fontSize),
              height: box.height,
              labelLeft: Math.round(text.left),
              inset: text.left - box.left,
              checkGap: mark.width > 0 ? Math.max(mark.left - text.right, text.left - mark.right) : null,
              fromMenu: box.left - menuBox.left,
            };
          });
          const titles = [...menu.querySelectorAll(".ui-menu-group-label")].map((title) => title.textContent);
          const more = [...menu.querySelectorAll('[role="menuitem"]')].some((item) =>
            item.textContent?.includes("More models"),
          );
          // The composer's model menu's text size and row height (modelPicker.css .acpmux-quick-menu):
          // a native menu's 13px chrome type, never the prompt's content size (Leo 2026-10-28: "AND
          // I THINK IT'S ALL SO STUPIDLY SPACED AND STYLED IT'S FUCKING TONKA TOYS").
          const probe = document.createElement("span");
          probe.style.fontSize = "var(--text-body)";
          menu.append(probe);
          const content = parseFloat(getComputedStyle(probe).fontSize);
          probe.remove();
          // The row height token is a calc() of the interface scale; a probe resolves it.
          const tall = document.createElement("div");
          tall.style.height = "var(--ui-row-height)";
          menu.append(tall);
          const rowHeight = tall.getBoundingClientRect().height;
          tall.remove();
          return { rows, titles, more, content, rowHeight };
        });
        expect(geometry.titles).toEqual(["Retry with another model"]);
        expect(geometry.more, "older models fold under More models").toBe(true);
        for (const row of geometry.rows) {
          expect(row.fontSize, "the menu's chrome text size").toBe(geometry.content);
          expect(row.height, "a menu row's height").toBeLessThanOrEqual(geometry.rowHeight);
          expect(row.inset, "the label is inset in its row").toBeGreaterThanOrEqual(6);
          expect(row.fromMenu, "rows are inset from the menu's edge").toBeGreaterThanOrEqual(3);
        }
        expect(new Set(geometry.rows.map((row) => row.labelLeft)).size, "every label starts at the same x").toBe(1);
        // An unchecked row's detail stays in the label's cell, never the check column, so it never runs
        // past the menu's edge (the gallery's "Fable 5.1 · 1M context" drew "1M" over the edge).
        const details = geometry.rows.filter((row) => row.detail);
        expect(details.length, "the fixture has a row with a detail").toBeGreaterThan(0);
        for (const row of details)
          expect(row.detail, `${row.name}: its detail sits in the row, after the name, on its line`).toEqual({
            inRow: true,
            inMenu: true,
            sameLine: true,
          });
        const chosen = geometry.rows.find((row) => row.checked)!;
        expect(chosen.checkGap, "the check sits in its own column, clear of the name").toBeGreaterThanOrEqual(6);
        await page.close();
      });
  for (const [engine] of engines)
    for (const theme of ["Catppuccin Mocha", "Apple System Colors Light"])
      test(`${engine}, ${theme}: Retry stays revealed until its menu closes`, async () => {
        const page = await open(engine, 560, theme);
        try {
          await page.mouse.move(4, 4);
          await eased(page);
          const button = page.locator('button[aria-label="Retry with another model"]');
          expect(await button.getAttribute("data-popup-open")).toBe("");
          expect(await page.locator(".cv-user__actions").evaluate((node) => getComputedStyle(node).opacity)).toBe("1");
          await page.keyboard.press("Escape");
          await page.waitForFunction(() => !document.querySelector(".cv-turn-retry-menu[data-popup-open]"));
          expect(await button.getAttribute("data-popup-open")).toBeNull();
        } finally {
          await page.close();
        }
      });
});
