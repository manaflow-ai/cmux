// Leo 10-15 (preview build): on the New Tab page, the model picker opened under the search
// suggestions. A composer menu opened while the suggestions show draws over them, as Codex
// desktop's composer menus always do: a press on the menu's rows reaches the menu, never a
// suggestion. Same for the reasoning (effort) menu, and the other way around: suggestions that
// open while a menu shows stay under it.
//
// Both layouts: the threads template keeps the composer at the top, where the short window's menus
// open down over the suggestions; the default (stage) layout keeps it at the foot, its chips in the
// footer under the box, and the suggestions open above it. Where a menu does lie over the
// suggestions, a press on its rows reaches the menu; the top layout must show that overlap.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-menu-over-suggestions.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-menu-over-suggestions: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab menu over suggestions", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let utilities = "";
  beforeAll(async () => {
    const { compileTailwind } = await import("../scripts/agent-pane/tailwindCompile.mjs");
    utilities = await compileTailwind(path.join(webviews, "src/agent-session/acpmux/tailwind.css"));
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/new-tab-picker.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function openPage(query = "", height = 720): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height } });
    await page.goto(`http://127.0.0.1:${port}/test/browser/new-tab-picker.html${query}`);
    await page.addStyleTag({ content: utilities });
    await page.locator(".nt-field").waitFor({ timeout: 90_000 });
    return page;
  }

  async function suggest(page: Page) {
    await page.locator(".nt-field").click();
    await page.keyboard.type("re");
    await page.locator(".nt-popover .nt-row").first().waitFor();
  }

  /** The menu's rows that lie over the suggestions, and those where a press lands on something else. */
  async function covered(page: Page, menuSelector: string, rowSelector: string) {
    await page.waitForFunction((selector) => {
      const node = document.querySelector<HTMLElement>(selector);
      return !!node && getComputedStyle(node).visibility === "visible" && node.getBoundingClientRect().height > 0;
    }, menuSelector);
    // Past the open animation.
    await page.waitForTimeout(400);
    return page.evaluate(
      ({ menuSelector, rowSelector }) => {
        const menu = document.querySelector<HTMLElement>(menuSelector)!;
        const suggestions = document.querySelector(".nt-popover")!.getBoundingClientRect();
        const rows = [...menu.querySelectorAll<HTMLElement>(rowSelector)];
        const overlapping = rows.filter((row) => {
          const box = row.getBoundingClientRect();
          return (
            box.bottom > suggestions.top &&
            box.top < suggestions.bottom &&
            box.right > suggestions.left &&
            box.left < suggestions.right
          );
        });
        const misses = overlapping
          .map((row) => {
            const box = row.getBoundingClientRect();
            const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
            return menu.contains(hit) ? null : `${row.textContent?.trim().slice(0, 24)} -> ${hit?.className}`;
          })
          .filter(Boolean);
        return { overlapping: overlapping.length, misses };
      },
      { menuSelector, rowSelector },
    );
  }

  const MENUS = [
    {
      name: "model",
      query: "",
      height: 720,
      button: ".acpmux-model-name",
      menu: ".acpmux-mp[role=dialog]",
      rows: "[role=option]",
    },
    {
      name: "effort",
      query: "?reported",
      // Too short for the menu over its chip: it opens down, over the suggestions.
      height: 400,
      button: ".acpmux-effort .acpmux-picker-button",
      menu: ".acpmux-effort-menu",
      rows: "[role=menuitemradio]",
    },
    {
      name: "access",
      query: "?reported",
      // Too short for the menu over its chip: it opens down, over the suggestions.
      height: 400,
      button: ".acpmux-access-trigger",
      menu: ".acpmux-access-menu",
      rows: "[role=menuitemradio]",
    },
  ];

  const LAYOUTS = [
    { layout: "top", template: "threads", mustOverlap: true },
    { layout: "stage", template: "", mustOverlap: false },
  ];
  const withTemplate = (query: string, template: string) =>
    template ? `${query ? `${query}&` : "?"}template=${template}` : query;

  for (const { layout, template, mustOverlap } of LAYOUTS)
    for (const { name, query, height, button, menu, rows } of MENUS) {
      test(`${layout}: the ${name} menu opened over the suggestions takes the presses on its rows`, async () => {
        const page = await openPage(withTemplate(query, template), height);
        await suggest(page);
        await page.locator(button).first().click();
        const result = await covered(page, menu, rows);
        console.log(`${layout}: ${name} menu over suggestions`, JSON.stringify(result));
        if (mustOverlap) expect(result.overlapping).toBeGreaterThan(0);
        expect(result.misses).toEqual([]);
        await page.close();
      });
    }

  for (const { layout, template, mustOverlap } of LAYOUTS)
    for (const { name, query, height, button, menu, rows } of MENUS) {
      test(`${layout}: suggestions that open while the ${name} menu shows stay under it`, async () => {
        const page = await openPage(withTemplate(query, template), height);
        await page.locator(button).first().click();
        await page.locator(menu).waitFor();
        // The field takes text without a press elsewhere (which would close the menu), as the host's
        // dictation or a paste lands there.
        await page.evaluate(() => {
          const field = document.querySelector<HTMLTextAreaElement>(".nt-field")!;
          Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, "value")!.set!.call(field, "re");
          field.dispatchEvent(new Event("input", { bubbles: true }));
        });
        await page.locator(".nt-popover .nt-row").first().waitFor();
        const result = await covered(page, menu, rows);
        console.log(`${layout}: suggestions under the open ${name} menu`, JSON.stringify(result));
        if (mustOverlap) expect(result.overlapping).toBeGreaterThan(0);
        expect(result.misses).toEqual([]);
        await page.close();
      });
    }
});
