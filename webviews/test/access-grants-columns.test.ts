// cmux-web-test-timeout: 300
// The permission menu's allowed rules (ComposerPickers.tsx, "Granted access") sit on the mode rows'
// columns, and only their remove x lights on hover. The section is a fieldset, and the fieldset's own
// padding put the heading 6px and each rule 4px left of the modes' text, with the x 21px inside their
// number and check column; the whole rule row took a hover wash around its small x (Leo 2026-10-27:
// "why are you giving it the entire row when it's only this small little section? Just don't do
// that. Don't ever do that."). design/grid.md: every row type starts its text on the surface's
// `text` line and centers its trailing mark on `trail`, from the inline start in a right-to-left menu too.
// Real Chromium and WebKit (the app's engine) on the gallery stage. CI fails the file when it cannot
// launch them (requireBrowserLane). Locally: CMUX_BROWSER_TESTS=1 bun test test/access-grants-columns.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("access-grants-columns.test.ts", async () => {
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
      console.warn(`access grants: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("access grants", () => test("browsers", () => {}));
    return;
  }

  const ENTRY = "agent-pane.composer-pickers";
  // The closed stage: the access-grants variant's play removes a rule before a test could read the menu.
  const VARIANT = "closed";
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const stageURL = (theme: string) =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(ENTRY, { variant: VARIANT, frame: "component", width: 640, theme })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    await warmGalleryFrame(vite, ENTRY, { browser: [...browsers.values()][0], params: { variant: VARIANT } });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  const open = async (engine: string, theme: string, dir: "ltr" | "rtl"): Promise<Page> => {
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 640, height: 640 } });
    await page.goto(stageURL(theme));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.evaluate(() => document.fonts.ready);
    // The gallery has no direction switch; the menu portals into the document and inherits its dir.
    await page.evaluate((value) => {
      document.documentElement.dir = value;
    }, dir);
    await page.getByRole("button", { name: "Mode", exact: true }).click();
    await page.locator(".acpmux-access-grants .acpmux-access-grant").first().waitFor();
    return page;
  };

  const cases: [string, "ltr" | "rtl"][] = [
    ["Catppuccin Mocha", "ltr"],
    ["Apple System Colors Light", "ltr"],
    ["Catppuccin Mocha", "rtl"],
  ];
  for (const [engine] of engines)
    for (const [theme, dir] of cases)
      test(`${engine}, ${theme}, ${dir}: allowed rules start on the modes' text column and their x on the modes' trailing column`, async () => {
        const page = await open(engine, theme, dir);
        const geometry = await page.evaluate(() => {
          const menu = document.querySelector<HTMLElement>(".acpmux-access-menu")!;
          const rtl = getComputedStyle(menu).direction === "rtl";
          // Where a line of text starts: its left edge, or its right edge in a right-to-left menu.
          const textStart = (element: Element) => {
            const range = document.createRange();
            range.selectNodeContents(element);
            const box = range.getBoundingClientRect();
            return rtl ? box.right : box.left;
          };
          const center = (element: Element) => {
            const box = element.getBoundingClientRect();
            return box.left + box.width / 2;
          };
          const modes = [...menu.querySelectorAll<HTMLElement>(".acpmux-access-item")];
          // A mode's trailing mark: its number, or the check on the chosen row.
          const marks = modes
            .map((row) =>
              [...row.querySelectorAll(".ui-menu-shortcut, .ui-menu-check")].find(
                (mark) => mark.getBoundingClientRect().width > 0 && getComputedStyle(mark).visibility !== "hidden",
              ),
            )
            .filter((mark): mark is Element => mark !== undefined);
          return {
            direction: getComputedStyle(menu).direction,
            modeText: modes.map((row) => textStart(row.querySelector(".acpmux-menu-label")!)),
            modeTrail: marks.map(center),
            heading: textStart(menu.querySelector(".acpmux-access-grants-heading")!),
            grantText: [...menu.querySelectorAll(".acpmux-access-grant-label")].map(textStart),
            grantTrail: [...menu.querySelectorAll(".acpmux-access-grant-remove")].map(center),
          };
        });
        expect(geometry.direction, "the menu takes the document's direction").toBe(dir);
        expect(geometry.modeText.length, "the fixture has modes").toBeGreaterThan(0);
        expect(geometry.modeTrail.length, "the modes show a number or check").toBeGreaterThan(0);
        expect(geometry.grantText.length, "the fixture has allowed rules").toBe(2);
        const text = geometry.modeText[0]!;
        const trail = geometry.modeTrail[0]!;
        for (const left of geometry.modeText)
          expect(Math.abs(left - text), "the modes share one text column").toBeLessThan(0.5);
        expect(Math.abs(geometry.heading - text), "the heading starts on the modes' text").toBeLessThan(0.5);
        for (const left of geometry.grantText)
          expect(Math.abs(left - text), "a rule starts on the modes' text").toBeLessThan(0.5);
        for (const x of geometry.grantTrail)
          expect(Math.abs(x - trail), "a rule's x centers on the modes' trailing column").toBeLessThan(0.5);

        // Hovering a rule lights nothing; hovering its x lights the x alone.
        const row = page.locator(".acpmux-access-grant").first();
        await row.locator(".acpmux-access-grant-label").hover();
        const wash = () => row.evaluate((element) => getComputedStyle(element).backgroundColor);
        const clear = (color: string) => color === "transparent" || /^rgba\(.*,\s*0\)$/.test(color);
        expect(clear(await wash()), "a rule's row takes no hover wash").toBe(true);
        await row.locator(".acpmux-access-grant-remove").hover();
        expect(clear(await wash()), "hovering the x lights no row").toBe(true);
        await page.close();
      });
});
