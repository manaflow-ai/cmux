// cmux-web-test-timeout: 240
// A Settings search shows its results, in real engines (headless Chromium and WebKit from
// Playwright) on the settings dev server with the in-memory mock (`?mock`):
// - the matching rows are visible. Regression: Tailwind's `collapse` utility
//   (`visibility: collapse`) matched the page's open/close class, so a search showed an empty pane;
// - the groups without a match take no space. Regression: the refined look's group margin outranked
//   the closed group's, so each hidden group left a gap above the matches;
// - a query without a match says so.
//
// The engines come from `playwright install chromium webkit`. Where one is not installed, its
// cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("settings-search-results.test.ts", async () => {
  setDefaultTimeout(120_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      console.warn(`settings-search-results: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let base = "";
  // The page's utility classes, compiled as the app build does (the settings dev server compiles none).
  let utilities = "";

  beforeAll(async () => {
    if (engines.length === 0) return;
    const { compileTailwind } = await import("../scripts/agent-pane/tailwindCompile.mjs");
    utilities = await compileTailwind(path.join(webviews, "src/pages/settings/tailwind.css"));
    // The settings dev server, in this process: `listen()` resolves once it takes requests.
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.settings-page.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    await warmViteServer(vite, "/");
  }, 180_000);

  afterAll(async () => {
    await vite?.close();
  });

  /** Types `query` into the search field and waits until the results have settled. */
  const search = async (page: Page, query: string) => {
    await page.goto(`${base}/?mock`);
    await page.addStyleTag({ content: utilities });
    await page.waitForSelector("[data-settings-search]");
    await page.fill("[data-settings-search]", query);
    await page.waitForSelector("[data-search-results]");
    // The collapse transitions end; the results no longer move.
    await page.waitForFunction(() => !document.getAnimations().some((animation) => animation instanceof CSSTransition));
  };

  for (const [name, engine] of engines) {
    describe(name, () => {
      test("the matching rows are visible and the groups without a match take no space", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
          await search(page, "font");
          const state = await page.evaluate(() => {
            const sections = [...document.querySelectorAll(".result-section[data-open]")];
            const rows = sections.flatMap((section) => [
              ...section.querySelectorAll(".collapse[data-open] [data-row-key]"),
            ]);
            const hidden = sections.flatMap((section) => [
              ...section.querySelectorAll(".group.collapse:not([data-open])"),
            ]);
            return {
              sections: sections.length,
              rows: rows.map((row) => ({
                key: row.getAttribute("data-row-key"),
                visibility: getComputedStyle(row).visibility,
                height: row.getBoundingClientRect().height,
              })),
              hiddenGroupSpace: hidden.map((group) => {
                const style = getComputedStyle(group);
                return (
                  group.getBoundingClientRect().height + parseFloat(style.marginTop) + parseFloat(style.marginBottom)
                );
              }),
            };
          });
          expect(state.sections).toBeGreaterThan(0);
          expect(state.rows.length).toBeGreaterThan(0);
          expect(state.rows.filter((row) => row.visibility !== "visible" || row.height === 0)).toEqual([]);
          expect(state.hiddenGroupSpace.length).toBeGreaterThan(0);
          expect(state.hiddenGroupSpace.filter((space) => space > 0)).toEqual([]);
        } finally {
          await browser.close();
        }
      });

      test("a search card draws its edges like a section card", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
          await search(page, "font");
          const cards = await page.evaluate(() =>
            [...document.querySelectorAll(".result-section[data-open] .group.collapse[data-open] .rows")].map(
              (card) => {
                const shown = [...card.querySelectorAll(":scope > .collapse[data-open] > .collapse-body > .row")];
                const style = (row: Element) => getComputedStyle(row);
                return {
                  group: card.closest("[data-group]")?.getAttribute("data-group"),
                  shown: shown.length,
                  firstTopRadius: style(shown[0]!).borderTopLeftRadius,
                  lastBottomRadius: style(shown.at(-1)!).borderBottomLeftRadius,
                  lastDivider: style(shown.at(-1)!).boxShadow,
                  innerDividers: shown.slice(0, -1).filter((row) => style(row).boxShadow === "none").length,
                };
              },
            ),
          );
          expect(cards.length).toBeGreaterThan(0);
          expect(cards.some((card) => card.shown > 1)).toBe(true);
          // The divider under the last shown row drew a second line under the card's rounded edge.
          expect(cards.filter((card) => card.lastDivider !== "none")).toEqual([]);
          expect(cards.filter((card) => card.innerDividers > 0)).toEqual([]);
          expect(cards.filter((card) => card.firstTopRadius === "0px" || card.lastBottomRadius === "0px")).toEqual([]);
        } finally {
          await browser.close();
        }
      });

      test("a query without a match says No Results", async () => {
        const browser = await engine.launch({ headless: true });
        try {
          const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
          await search(page, "zzqxnomatch");
          const empty = await page.evaluate(() => {
            const line = document.querySelector("[data-search-results] > .empty")!;
            return {
              open: line.hasAttribute("data-open"),
              visibility: getComputedStyle(line).visibility,
              height: line.getBoundingClientRect().height,
            };
          });
          expect(empty.open).toBe(true);
          expect(empty.visibility).toBe("visible");
          expect(empty.height).toBeGreaterThan(0);
        } finally {
          await browser.close();
        }
      });
    });
  }
});
