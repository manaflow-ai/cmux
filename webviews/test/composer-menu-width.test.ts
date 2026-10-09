// The composer's menus keep their own width in real engines (headless Chromium and WebKit from
// Playwright). The Model chip is its menu's containing block (`position: relative`,
// so useUiAnchor places the menu against the chip), and the chip is about 120px wide: the menu's
// width must come from its content and the viewport, never from the chip. The location menu is
// portaled into a Base UI positioner on the body and must still get the pane's surface color.
//
// The page is the pane's real stylesheets plus markup in the shape the components render, with the
// inline style useUiAnchor sets. The engines come from `playwright install chromium webkit`; where
// they are not installed, the cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-menu-width.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src/agent-session");
  const css = [
    "shared/styles.css",
    "acpmux/styles.css",
    "acpmux/composerControls.css",
    "acpmux/composerLocation.css",
    "acpmux/modelPicker.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");

  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`composer-menu-width: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  /// The inline style useUiAnchor gives an open menu (src/ui/anchor.ts).
  const ANCHORED = "position:absolute;left:0px;top:-260px;right:auto;bottom:auto;visibility:visible";
  const row = (label: string) =>
    `<div class="acpmux-menu-item"><span class="acpmux-menu-text"><span class="acpmux-menu-label">${label}</span></span></div>`;
  const PAGE = `<!doctype html><html><head><style>
:root{--agent-text:rgb(205,214,244);--agent-accent-text:rgb(30,30,46);--agent-page-bg:rgb(30,30,46);--agent-muted:rgb(166,173,200)}
${css}
</style></head><body>
<div class="acpmux-shell"><div class="acpmux-composer" style="margin-top:320px">
  <span class="acpmux-picker acpmux-model" style="position:relative">
    <button class="acpmux-picker-button" style="width:120px">GPT-6-Astra</button>
    <div class="acpmux-menu acpmux-menu-end acpmux-mp acpmux-mp-cascade" style="${ANCHORED}">
      <div class="acpmux-menu-search">Type to search models</div>${row("Codex")}${row("GPT-5.6-Sol")}${row("GPT-6-Astra")}
    </div>
  </span>
</div></div>
<div class="ui-positioner" style="position:absolute;left:8px;top:8px">
  <div class="acpmux-menu acpmux-location-menu">${row("~/fun/cmuxterm-hq")}</div>
</div>
</body></html>`;

  type Box = { width: number; left: number; right: number };
  const box = (page: Page, selector: string): Promise<Box> =>
    page.$eval(selector, (node) => {
      const rect = node.getBoundingClientRect();
      return { width: rect.width, left: rect.left, right: rect.right };
    });

  for (const [name, engine] of engines) {
    describe(`composer menus in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      const open = async (width: number) => {
        const page = await browser.newPage({ viewport: { width, height: 700 } });
        await page.setContent(PAGE);
        return page;
      };

      test("the Model menu is at least 220px wide, wider than its 120px chip", async () => {
        const page = await open(1000);
        const menu = await box(page, ".acpmux-model .acpmux-menu");
        expect(menu.width).toBeGreaterThanOrEqual(220);
        expect(menu.width).toBeLessThanOrEqual(420);
        await page.close();
      });

      test("in a 200px pane the Model menu still fits inside the pane's margins", async () => {
        const page = await open(200);
        expect((await box(page, ".acpmux-model .acpmux-menu")).width).toBeLessThanOrEqual(200 - 16);
        await page.close();
      });

      test("the portaled location menu gets the pane's menu surface, not a clear background", async () => {
        const page = await open(1000);
        const background = await page.$eval(
          ".ui-positioner .acpmux-location-menu",
          (node) => getComputedStyle(node).backgroundColor,
        );
        expect(background).not.toBe("rgba(0, 0, 0, 0)");
        expect((await box(page, ".ui-positioner .acpmux-location-menu")).width).toBeGreaterThanOrEqual(200);
        await page.close();
      });
    });
  }
});
