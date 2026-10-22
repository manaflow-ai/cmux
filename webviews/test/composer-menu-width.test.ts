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
  // The liquid glass first, as build-agent-pane-web.sh loads it: every popup's material.
  const css = [
    "../ui/glass/glass.css",
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

  /// The inline style useUiAnchor gives an open menu (src/ui/anchor.ts). At a 200px viewport the
  /// anchor's 8px margin clamps the surface to x=8, so the narrow case can check both edges.
  const ANCHORED = "position:absolute;left:8px;top:-260px;right:auto;bottom:auto;visibility:visible";
  const row = (label: string) =>
    `<div class="acpmux-menu-item"><span class="acpmux-menu-text"><span class="acpmux-menu-label">${label}</span></span></div>`;
  const modelRow = (label: string) => `<button class="acpmux-mp-row">${label}</button>`;
  const PAGE = `<!doctype html><html><head><style>
:root{--agent-text:rgb(205,214,244);--agent-accent-text:rgb(30,30,46);--agent-page-bg:rgb(30,30,46);--agent-muted:rgb(166,173,200)}
${css}
.flex{display:flex}
</style></head><body>
<div class="acpmux-shell"><div class="acpmux-composer" style="flex:1;margin-top:320px;padding:0"><div class="acpmux-composer-bar">
  <span class="acpmux-picker acpmux-composer-plus"><button class="acpmux-picker-button" style="width:28px">+</button></span>
  <div class="acpmux-chips">
  <span class="acpmux-picker acpmux-model" style="position:relative">
    <button class="acpmux-picker-button"><span class="acpmux-model-name" data-fit-part="model" data-fit-forms="full">GPT-6-Astra</span></button>
    <div class="ui-popup ui-glass ui-picker-popup acpmux-mp flex" style="${ANCHORED}">
      <div class="acpmux-mp-rail-scroll w-11 flex-none">
        <div class="acpmux-mp-rail-viewport" style="overflow:scroll">
          <div class="acpmux-mp-rail-list flex flex-col items-center gap-1 py-1.5">
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="width:32px;height:32px;flex:none">
              Claude Code
            </button>
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="width:32px;height:32px;flex:none">
              Codex
            </button>
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="width:32px;height:32px;flex:none">
              Folder
            </button>
          </div>
        </div>
      </div>
      <div class="acpmux-mp-content">
        <div class="acpmux-mp-search">Type to search models</div>
        <div class="acpmux-mp-models">${modelRow("GPT-5.6-Sol")}${modelRow("GPT-6-Astra")}</div>
      </div>
    </div>
  </span>
  <span class="acpmux-mode acpmux-access">
    <button class="acpmux-picker-button acpmux-access-trigger">
      <span class="acpmux-icon" style="width:16px;height:16px"></span>
      <span class="acpmux-mode-text" data-fit-part="access" data-fit-forms="full">Ask before edits</span>
      <span class="acpmux-icon" style="width:12px;height:12px"></span>
    </button>
  </span>
  </div>
  <span class="acpmux-composer-actions"><button class="acpmux-send" style="width:28px;height:28px">↑</button></span>
</div></div></div>
<div class="ui-positioner" style="position:absolute;left:8px;top:8px">
  <div class="ui-glass acpmux-menu acpmux-location-menu">${row("~/fun/cmuxterm-hq")}</div>
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
        const menu = await box(page, ".acpmux-model .acpmux-mp");
        expect(menu.width).toBeGreaterThanOrEqual(220);
        expect(menu.width).toBeLessThanOrEqual(420);
        await page.close();
      });

      test("in a 200px pane the Model menu still fits inside the pane's margins", async () => {
        const page = await open(200);
        const menu = await box(page, ".acpmux-model .acpmux-mp");
        expect(menu.width).toBeLessThanOrEqual(200 - 16);
        const geometry = await page.$eval(".acpmux-model .acpmux-mp", (node) => {
          const menu = node as HTMLElement;
          const rail = menu.querySelector<HTMLElement>(".acpmux-mp-rail-scroll")!;
          const railList = menu.querySelector<HTMLElement>(".acpmux-mp-rail-list")!;
          const content = menu.querySelector<HTMLElement>(".acpmux-mp-content")!;
          return {
            menuScrollWidth: menu.scrollWidth,
            menuClientWidth: menu.clientWidth,
            menuLeft: menu.getBoundingClientRect().left,
            menuRight: menu.getBoundingClientRect().right,
            menuDisplay: getComputedStyle(menu).display,
            menuDirection: getComputedStyle(menu).flexDirection,
            railLeft: rail.getBoundingClientRect().left,
            railRight: rail.getBoundingClientRect().right,
            railWidth: rail.getBoundingClientRect().width,
            railHeight: rail.getBoundingClientRect().height,
            viewportWidth: menu.querySelector<HTMLElement>(".acpmux-mp-rail-viewport")!.getBoundingClientRect().width,
            viewportHeight: menu.querySelector<HTMLElement>(".acpmux-mp-rail-viewport")!.getBoundingClientRect().height,
            contentWidth: content.getBoundingClientRect().width,
            railListDisplay: getComputedStyle(railList).display,
            railDirection: getComputedStyle(railList).flexDirection,
            tabRects: [...menu.querySelectorAll<HTMLElement>(".acpmux-mp-rail-tab")].map((tab) => {
              const rect = tab.getBoundingClientRect();
              return { left: rect.left, right: rect.right, top: rect.top, width: rect.width, height: rect.height };
            }),
          };
        });
        expect(geometry.menuScrollWidth).toBeLessThanOrEqual(geometry.menuClientWidth);
        expect(geometry.menuLeft).toBeGreaterThanOrEqual(8);
        expect(geometry.menuRight).toBeLessThanOrEqual(200 - 8);
        expect(geometry.menuDisplay).toBe("flex");
        expect(geometry.menuDirection).toBe("column");
        expect(geometry.railDirection).toBe("row");
        expect(geometry.railListDisplay).toBe("flex");
        expect(geometry.railWidth).toBeLessThanOrEqual(menu.width);
        expect(geometry.railHeight).toBe(44);
        expect(geometry.viewportWidth).toBe(geometry.railWidth);
        expect(geometry.viewportHeight).toBeGreaterThanOrEqual(40);
        expect(geometry.viewportHeight).toBeLessThanOrEqual(geometry.railHeight);
        expect(geometry.contentWidth).toBeGreaterThan(0);
        expect(geometry.tabRects).toHaveLength(3);
        expect(geometry.tabRects.every((tab) => tab.width >= 24 && tab.width < geometry.railWidth / 2)).toBe(true);
        expect(geometry.tabRects.every((tab) => tab.height >= 24 && tab.height <= geometry.railHeight)).toBe(true);
        expect(
          Math.max(...geometry.tabRects.map((tab) => tab.top)) - Math.min(...geometry.tabRects.map((tab) => tab.top)),
        ).toBeLessThanOrEqual(1);
        expect(
          geometry.tabRects.every((tab) => tab.left >= geometry.railLeft && tab.right <= geometry.railRight + 1),
        ).toBe(true);
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

      // The permission chip hugs its mode's name (hq#1957 item 15: a fixed 180 px chip left a gap
      // inside it). It is the left cluster's last chip and the row's free space follows it, so a
      // mode change moves no other control: not the model before it, not Send at the row's end.
      test("permission mode changes move no other control", async () => {
        const page = await open(1000);
        const edges = await page.$eval(".acpmux-composer-bar", (node) => {
          const bar = node as HTMLElement;
          const mode = bar.querySelector<HTMLElement>(".acpmux-mode-text")!;
          return ["Ask before edits", "Full access", "Auto"].map((label) => {
            mode.textContent = label;
            return [".acpmux-model .acpmux-picker-button", ".acpmux-access-trigger", ".acpmux-send"].map(
              (selector) => bar.querySelector(selector)!.getBoundingClientRect().left,
            );
          });
        });
        expect(edges[0]![0]).toBeGreaterThan(0);
        expect(edges[1]).toEqual(edges[0]!);
        expect(edges[2]).toEqual(edges[0]!);
        await page.close();
      });

      test("the complete control rail stays inside narrow LTR and RTL panes", async () => {
        for (const width of [360, 240, 200, 180]) {
          for (const direction of ["ltr", "rtl"] as const) {
            const page = await open(width);
            await page.evaluate((dir) => document.documentElement.setAttribute("dir", dir), direction);
            const geometry = await page.$eval(".acpmux-composer-bar", (node) => {
              const bar = node as HTMLElement;
              const barRect = bar.getBoundingClientRect();
              const access = bar.querySelector<HTMLElement>(".acpmux-access-trigger")!.getBoundingClientRect();
              return {
                clientWidth: bar.clientWidth,
                scrollWidth: bar.scrollWidth,
                barLeft: barRect.left,
                barRight: barRect.right,
                accessLeft: access.left,
                accessRight: access.right,
              };
            });
            expect(geometry.scrollWidth).toBeLessThanOrEqual(geometry.clientWidth);
            expect(geometry.accessLeft).toBeGreaterThanOrEqual(geometry.barLeft - 1);
            expect(geometry.accessRight).toBeLessThanOrEqual(geometry.barRight + 1);
            await page.close();
          }
        }
      });

      test("Interrupt shows whole while a turn runs; the chips give way, not the action", async () => {
        for (const width of [600, 420, 360]) {
          const page = await open(width);
          await page.$eval(".acpmux-composer-actions", (node) => {
            node.innerHTML =
              '<button class="acpmux-steer">Interrupt</button>' +
              '<button class="acpmux-send" style="width:28px;height:28px">mic</button>' +
              '<button class="acpmux-send acpmux-send-ready">↑</button>';
          });
          const geometry = await page.$eval(".acpmux-composer-bar", (node) => {
            const bar = node.getBoundingClientRect();
            const steer = node.querySelector<HTMLElement>(".acpmux-steer")!;
            const rect = steer.getBoundingClientRect();
            return { barRight: bar.right, right: rect.right, client: steer.clientWidth, scroll: steer.scrollWidth };
          });
          expect(geometry.scroll).toBeLessThanOrEqual(geometry.client);
          expect(geometry.right).toBeLessThanOrEqual(geometry.barRight + 1);
          await page.close();
        }
      });
    });
  }
});
