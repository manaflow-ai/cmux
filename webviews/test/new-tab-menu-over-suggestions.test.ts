// Leo 10-15 (preview build): on the New Tab page, the model picker opened under the search
// suggestions. A composer menu opened while the suggestions show draws over them, as Codex
// desktop's composer menus always do: a press on the menu's rows reaches the menu, never a
// suggestion. Same for the access menu, and the other way around: suggestions that open while a
// menu shows stay under it. The model button opens its compact menu, which holds Effort (Leo
// 2026-10-20: one model button, no separate effort menu).
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
    // Past the open animation (finite animations only).
    await page.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((animation) => Number.isFinite(Number(animation.effect?.getComputedTiming().endTime)))
          .map((animation) => animation.finished.catch(() => undefined)),
      ),
    );
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
            const hit = document.elementFromPoint(
              (Math.max(box.left, suggestions.left) + Math.min(box.right, suggestions.right)) / 2,
              (Math.max(box.top, suggestions.top) + Math.min(box.bottom, suggestions.bottom)) / 2,
            );
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
      menu: ".acpmux-quick-menu",
      // A wrapped harness rail is the first part of the menu over the suggestions.
      // Its buttons must receive presses just like the model rows below it.
      rows: ".acpmux-quick-rail-tab, [role^=menuitem]",
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
  const withQuery = (query: string, more: string) => `${query ? `${query}&` : "?"}${more}`;
  // Default (the harness's unset template) is the stage layout: the composer at the foot, where the
  // access menu reaches over its suggestions (CI on #22119 measured 2 to 3 rows). The model button's
  // compact menu (Leo 2026-10-20) opens above the box there, clear of the suggestions under it (CI
  // on #22800 measured 0 rows), so only its presses are checked. Threads keeps the composer at the
  // top of the page: the model menu reaches over the suggestions there; the access menu opens clear
  // of them (0 rows), so only its presses are checked.
  const MENUS_ON: ((typeof MENUS)[number] & { mustOverlap: boolean })[] = [
    ...MENUS.map((entry) => ({
      ...entry,
      name: `${entry.name} (Default, stage)`,
      mustOverlap: entry.name !== "model",
    })),
    ...MENUS.map((entry) => ({
      ...entry,
      name: `${entry.name} (Threads)`,
      query: withQuery(entry.query, "template=threads"),
      mustOverlap: entry.name === "model",
    })),
  ];

  // Cards, the app's default page, draws Claude Code's split: the chips sit in the quiet row under
  // the box, and the suggestions hang under that row, never over it (greptile on #22285). There
  // the model menu reaches over the suggestions; the access menu opens clear of them
  // (CI on #22285 measured no overlap), so only the model menu has an overlap to check.
  for (const { name, query, height, button, menu, rows } of MENUS.filter((entry) => entry.name === "model")) {
    MENUS_ON.push({
      name: `${name} (Cards, split)`,
      query: `${query ? `${query}&` : "?"}template=cards`,
      height,
      button,
      menu,
      rows,
      mustOverlap: true,
    });
  }

  test("on Cards the suggestions open under the quiet row and leave its chips reachable", async () => {
    const page = await openPage("?reported&template=cards", 720);
    await suggest(page);
    const result = await page.evaluate(() => {
      const foot = document.querySelector(".nt-foot")!.getBoundingClientRect();
      const suggestions = document.querySelector(".nt-popover")!.getBoundingClientRect();
      const chips = [...document.querySelectorAll<HTMLElement>(".nt-foot button")].filter(
        (chip) => chip.getBoundingClientRect().width > 0,
      );
      const hidden = chips
        .map((chip) => {
          const box = chip.getBoundingClientRect();
          const hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
          return chip.contains(hit) ? null : `${chip.className} -> ${hit?.className}`;
        })
        .filter(Boolean);
      return { gap: suggestions.top - foot.bottom, chips: chips.length, hidden };
    });
    console.log("Cards suggestions under the quiet row", JSON.stringify(result));
    expect(result.chips).toBeGreaterThan(0);
    expect(result.gap).toBeGreaterThanOrEqual(0);
    expect(result.hidden).toEqual([]);
    await page.close();
  });

  for (const { name, query, height, button, menu, rows, mustOverlap } of MENUS_ON) {
    test(`the ${name} menu opened over the suggestions takes the presses on its rows`, async () => {
      const page = await openPage(query, height);
      await suggest(page);
      await page.locator(button).first().click();
      const result = await covered(page, menu, rows);
      console.log(`${name} menu over suggestions`, JSON.stringify(result));
      if (mustOverlap) expect(result.overlapping).toBeGreaterThan(0);
      expect(result.misses).toEqual([]);
      await page.close();
    });
  }

  for (const { name, query, height, button, menu, rows, mustOverlap } of MENUS_ON) {
    test(`suggestions that open while the ${name} menu shows stay under it`, async () => {
      const page = await openPage(query, height);
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
      console.log(`suggestions under the open ${name} menu`, JSON.stringify(result));
      if (mustOverlap) expect(result.overlapping).toBeGreaterThan(0);
      expect(result.misses).toEqual([]);
      await page.close();
    });
  }
});
