// l10n-allow-file: test assertions on the page's English labels, not shipped UI.
// The Passwords page in a narrow pane (a standalone 360 px pane, the gallery's narrow width): the
// header's title and its actions all stay on screen (the actions wrap under the title rather than
// pushing "Import from Browser" off the edge and the title to nothing), saved logins keep a readable
// username (the badges, last-used and actions wrap under it) while passkey and exception rows stay
// one line, and the controls in a header row share one height. At the normal width nothing wraps.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("passwords-narrow.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const PAGE = "/src/pages/passwords/index.html?mock";
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
    await warmViteServer(vite, PAGE);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(width: number, colorScheme: "light" | "dark" = "light"): Promise<Page> {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width, height: 720 }, colorScheme });
    await page.goto(`http://127.0.0.1:${port}${PAGE}`);
    await page.locator(".pw-site .pw-row .pw-username").first().waitFor();
    return page;
  }

  const measure = (page: Page) =>
    page.evaluate(() => {
      const box = (element: Element) => element.getBoundingClientRect();
      const header = box(document.querySelector(".pw-header")!);
      const title = document.querySelector<HTMLElement>(".pw-title")!;
      const titleRow = [...document.querySelectorAll(".pw-title-row > *")].map(box);
      const searchRow = [...document.querySelectorAll(".pw-search-row > *")].map(box);
      const rows = [...document.querySelectorAll(".pw-site .pw-row")].map((row) => {
        const name = row.querySelector<HTMLElement>(".pw-username")!;
        const actions = box(row.querySelector(".pw-actions")!);
        return {
          name: box(name).width,
          wants: name.scrollWidth,
          nameTop: box(name).top,
          actionsTop: actions.top,
        };
      });
      return {
        header: { left: header.left, right: header.right },
        title: { shown: title.clientWidth, wants: title.scrollWidth },
        titleRow: {
          right: Math.max(...titleRow.map((b) => b.right)),
          lines: new Set(titleRow.map((b) => Math.round(b.top + b.height / 2))).size,
        },
        searchHeights: searchRow.map((b) => Math.round(b.height)),
        rows,
      };
    });

  describe("passwords page", () => {
    for (const theme of ["light", "dark"] as const) {
      test(`${theme}: only row buttons highlight on hover, press and keyboard focus`, async () => {
        const page = await open(900, theme);
        const background = (element: Locator) => element.evaluate((node) => getComputedStyle(node).backgroundColor);
        try {
          for (const section of ["pw-passwords", "pw-passkeys", "pw-exceptions"]) {
            const row = page.locator(`[aria-labelledby="${section}"] .pw-row`).first();
            await page.mouse.move(0, 0);
            const restingRow = await background(row);
            const buttons = row.locator(".pw-row-button");
            expect(await buttons.count()).toBeGreaterThan(0);
            const restingButtons = await Promise.all((await buttons.all()).map(background));

            // The left padding is blank space, outside every child control.
            await row.hover({ position: { x: 2, y: 2 } });
            expect(await background(row)).toBe(restingRow);
            expect(await Promise.all((await buttons.all()).map(background))).toEqual(restingButtons);

            // Includes Reveal, Copy, Edit and Delete, plus passkey/exception removal.
            for (const [index, button] of (await buttons.all()).entries()) {
              await button.hover();
              const hoveredButton = await background(button);
              expect(hoveredButton).not.toBe(restingButtons[index]);
              expect(await background(row)).toBe(restingRow);
              await page.mouse.down();
              try {
                expect(await button.evaluate((node) => node.matches(":active"))).toBe(true);
                expect(await background(button)).toBe(hoveredButton);
                expect(await background(row)).toBe(restingRow);
              } finally {
                // Release outside the row so destructive actions never run.
                await page.mouse.move(0, 0);
                await page.mouse.up();
              }

              await button.focus();
              await page.keyboard.press("Shift+Tab");
              await page.keyboard.press("Tab");
              const focus = await button.evaluate((node) => ({
                visible: node.matches(":focus-visible"),
                style: getComputedStyle(node).outlineStyle,
                width: Number.parseFloat(getComputedStyle(node).outlineWidth),
              }));
              expect(focus.visible).toBe(true);
              expect(focus.style).not.toBe("none");
              expect(focus.width).toBeGreaterThan(0);
              expect(await background(row)).toBe(restingRow);
            }
          }
        } finally {
          await page.close();
        }
      });
    }

    test("at 360 px the header and the saved logins fit the pane", async () => {
      const page = await open(360);
      const m = await measure(page);
      // Passkey and exception rows stay one line with a long site name: badge, name and actions.
      const oneLine = await page.evaluate(() =>
        [...document.querySelectorAll(".pw-section .pw-row")]
          .filter((row) => !row.closest(".pw-site"))
          .map((row) => {
            row.querySelector(".pw-site-name")!.textContent = "accounts.login.very-long-subdomain.example-bank.co.uk";
            const middles = [".pw-site-badge", ".pw-site-name", ".pw-actions"].map((selector) => {
              const box = row.querySelector(selector)!.getBoundingClientRect();
              return box.top + box.height / 2;
            });
            // The spread of their middles: under 8 px is one line (a wrapped item sits a row lower).
            return Math.max(...middles) - Math.min(...middles);
          }),
      );
      await page.close();
      expect(oneLine.length).toBeGreaterThan(0);
      for (const spread of oneLine) expect(spread).toBeLessThan(8);
      expect(m.title.shown).toBeGreaterThanOrEqual(m.title.wants);
      expect(m.titleRow.right).toBeLessThanOrEqual(360);
      for (const row of m.rows) expect(row.name).toBeGreaterThanOrEqual(Math.min(row.wants, 96));
      expect(new Set(m.searchHeights).size).toBe(1);
    });

    test("at 900 px the header and every login stay on one line", async () => {
      const page = await open(900);
      const m = await measure(page);
      await page.close();
      expect(m.titleRow.lines).toBe(1);
      for (const row of m.rows) expect(Math.abs(row.nameTop - row.actionsTop)).toBeLessThan(8);
      expect(new Set(m.searchHeights).size).toBe(1);
    });
  });
});
