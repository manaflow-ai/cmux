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
import { quantizePickerRail } from "../src/agent-session/acpmux/pickerRailGeometry";

await requireBrowserLane("composer-menu-width.test.ts", async () => {
  test("picker rail geometry helper is idempotent and clears wide overrides", () => {
    let width = "";
    const rail = {
      style: {
        setProperty: (_name: string, value: string) => {
          width = value;
        },
        removeProperty: () => {
          width = "";
        },
      },
    };
    const container = { clientWidth: 184, scrollWidth: 184 };
    const viewport = { clientWidth: 184, scrollWidth: 300 };
    quantizePickerRail(rail, container, viewport, true);
    const first = width;
    expect(first).toBe("152px");
    quantizePickerRail(rail, container, viewport, true);
    expect(width).toBe(first);
    expect(first).toBe("152px");
    quantizePickerRail(rail, container, { ...viewport, scrollWidth: 120 }, true);
    expect(width).toBe("");
    width = "152px";
    quantizePickerRail(rail, container, viewport, false);
    expect(width).toBe("");
  });

  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src/agent-session");
  // The desktop layer, then the liquid glass, as build-agent-pane-web.sh loads them: desktop.css holds
  // the design tokens the glass reads (its tint is `--ds-glass-plain-tint` since #24589), and the
  // glass is every popup's material.
  const css = [
    "../pages/shared/desktop.css",
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
  const ANCHORED = "position:absolute;left:8px;top:8px;right:auto;bottom:auto;visibility:visible";
  const row = (label: string) =>
    `<div class="acpmux-menu-item"><span class="acpmux-menu-text"><span class="acpmux-menu-label">${label}</span></span></div>`;
  const modelRow = (label: string) => `<button class="acpmux-mp-row">${label}</button>`;
  const PAGE = `<!doctype html><html><head><style>
:root{--agent-text:rgb(205,214,244);--agent-accent-text:rgb(30,30,46);--agent-page-bg:rgb(30,30,46);--agent-muted:rgb(166,173,200)}
${css}
.acpmux-mp-rail-viewport::-webkit-scrollbar{display:none}
.flex{display:flex}
</style></head><body>
<div class="acpmux-shell"><div class="acpmux-composer" style="flex:1;margin-top:320px;padding:0"><div class="acpmux-composer-bar">
  <span class="acpmux-picker acpmux-composer-plus"><button class="acpmux-picker-button" style="width:28px">+</button></span>
  <div class="acpmux-chips">
  <span class="acpmux-picker acpmux-model" style="position:relative">
    <button class="acpmux-picker-button"><span class="acpmux-model-name" data-fit-part="model" data-fit-forms="full">GPT-6-Astra</span></button>
    <div class="ui-popup ui-glass ui-picker-popup acpmux-mp flex" style="${ANCHORED}">
      <div class="acpmux-mp-rail-scroll w-11 flex-none">
        <div class="acpmux-mp-rail-viewport" style="overflow-x:scroll;overflow-y:hidden;scrollbar-width:none;width:100%;max-width:100%">
          <div class="acpmux-mp-rail-list flex flex-col items-center gap-1 py-1.5">
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="height:32px;flex:none">
              Claude Code
            </button>
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="height:32px;flex:none">
              Codex
            </button>
            <button class="acpmux-mp-rail-tab grid size-8 flex-none" style="height:32px;flex:none">
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
              return {
                left: rect.left,
                right: rect.right,
                top: rect.top,
                width: rect.width,
                height: rect.height,
              };
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

      test("the horizontal harness strip keeps endpoints whole or as a bounded faded peek", async () => {
        for (const width of [200, 360]) {
          for (const count of [3, 8, 15]) {
            const page = await open(width);
            await page.$eval(
              ".acpmux-mp-rail-list",
              (list, total) => {
                list.innerHTML = Array.from(
                  { length: total as number },
                  (_, index) =>
                    '<button class="acpmux-mp-rail-tab grid size-8 flex-none" data-tab-index="' +
                    index +
                    '" style="height:32px;flex:none">Harness ' +
                    (index + 1) +
                    "</button>",
                ).join("");
              },
              count,
            );
            await page.$eval(".acpmux-mp-rail-list", (list) => {
              (list as HTMLElement).style.cssText +=
                ";display:flex;flex-direction:row;gap:4px;width:max-content;min-width:max-content;padding:6px";
            });
            if (count > 3) {
              await page.$eval(".acpmux-mp-rail-scroll", (rail) => {
                (rail as HTMLElement).style.setProperty("width", "100px", "important");
              });
            }
            const endpoint = async (position: "start" | "middle" | "end") => {
              if (position === "middle") {
                const box = await page.$eval(".acpmux-mp-rail-viewport", (node) => {
                  const rect = (node as HTMLElement).getBoundingClientRect();
                  return {
                    x: rect.left + rect.width / 2,
                    y: rect.top + rect.height / 2,
                    width: (node as HTMLElement).scrollWidth,
                  };
                });
                await page.mouse.move(box.x, box.y);
                await page.$eval(".acpmux-mp-rail-viewport", (node) => {
                  const viewport = node as HTMLElement;
                  const target = Math.min(viewport.scrollWidth - viewport.clientWidth - 1, 72);
                  viewport.scrollLeft = Math.max(1, target);
                });
              } else {
                await page.$eval(
                  ".acpmux-mp-rail-viewport",
                  (node, side) => {
                    const viewport = node as HTMLElement;
                    viewport.scrollLeft = side === "start" ? 0 : viewport.scrollWidth;
                  },
                  position,
                );
              }
              await page.waitForFunction(
                (selector) => {
                  const viewport = document.querySelector<HTMLElement>(selector)! as HTMLElement & {
                    __cmuxLastScroll?: number;
                    __cmuxStableFrames?: number;
                  };
                  const current = viewport.scrollLeft;
                  if (viewport.__cmuxLastScroll === current) {
                    viewport.__cmuxStableFrames = (viewport.__cmuxStableFrames ?? 0) + 1;
                  } else {
                    viewport.__cmuxLastScroll = current;
                    viewport.__cmuxStableFrames = 0;
                  }
                  return (viewport.__cmuxStableFrames ?? 0) >= 2;
                },
                ".acpmux-mp-rail-viewport",
                { polling: "raf", timeout: 1000 },
              );
              return page.$eval(".acpmux-mp-rail-viewport", (node) => {
                const viewport = node as HTMLElement;
                const viewportBox = viewport.getBoundingClientRect();
                return {
                  mask: getComputedStyle(viewport).maskImage,
                  snapType: getComputedStyle(viewport).scrollSnapType,
                  tabSnap: getComputedStyle(viewport.querySelector<HTMLElement>(".acpmux-mp-rail-tab")!)
                    .scrollSnapAlign,
                  gaps: [...viewport.querySelectorAll<HTMLElement>(".acpmux-mp-rail-tab")]
                    .slice(1)
                    .map((tab, index) => {
                      const previous = viewport
                        .querySelectorAll<HTMLElement>(".acpmux-mp-rail-tab")
                        [index]!.getBoundingClientRect();
                      return tab.getBoundingClientRect().left - previous.right;
                    }),
                  scrollLeft: viewport.scrollLeft,
                  maxScroll: Math.max(0, viewport.scrollWidth - viewport.clientWidth),
                  tabs: [...viewport.querySelectorAll<HTMLElement>(".acpmux-mp-rail-tab")]
                    .map((tab) => {
                      const box = tab.getBoundingClientRect();
                      const left = Math.max(box.left, viewportBox.left);
                      const right = Math.min(box.right, viewportBox.right);
                      return { visibleWidth: Math.max(0, right - left), fullWidth: box.width };
                    })
                    .filter((tab) => tab.visibleWidth > 0),
                };
              });
            };
            const startState = await endpoint("start");
            const middleState = await endpoint("middle");
            const endState = await endpoint("end");
            expect(startState.tabs.length).toBeGreaterThan(0);
            expect(endState.tabs.length).toBeGreaterThan(0);
            if (count > 3) {
              expect(middleState.maxScroll).toBeGreaterThan(0);
              expect(middleState.scrollLeft).toBeGreaterThan(0);
              if (middleState.maxScroll > 36) expect(middleState.scrollLeft).toBeLessThan(middleState.maxScroll);
            }
            expect(startState.mask).toContain("linear-gradient");
            expect(middleState.mask).toContain("linear-gradient");
            expect(endState.mask).toContain("linear-gradient");
            expect(startState.snapType).toContain("mandatory");
            expect(startState.tabSnap).toContain("start");
            expect(new Set(startState.gaps.map((gap) => Math.round(gap))).size).toBe(1);
            expect(startState.gaps.every((gap) => Math.abs(gap - 4) < 0.5)).toBe(true);
            for (const [label, state] of [
              ["start", startState],
              ["middle", middleState],
              ["end", endState],
            ] as const) {
              const clipped = state.tabs.filter((tab) => tab.visibleWidth + 0.5 < tab.fullWidth);
              expect(clipped.length).toBeLessThanOrEqual(label === "middle" ? 2 : 1);
              expect(clipped.every((tab) => tab.fullWidth - tab.visibleWidth <= 31.5)).toBe(true);
            }
            await page.close();
          }
        }
      });

      test("reduced transparency clips rail edge hit targets at every narrow width", async () => {
        for (const width of [200, 320, 360]) {
          const page = await open(width);
          await page.$eval(".acpmux-mp-rail-list", (list) => {
            const node = list as HTMLElement;
            node.innerHTML = Array.from(
              { length: 15 },
              (_, index) =>
                '<button class="acpmux-mp-rail-tab grid size-8 flex-none" data-tab-index="' +
                index +
                '" style="height:32px;flex:none">Harness ' +
                (index + 1) +
                "</button>",
            ).join("");
            node.style.cssText +=
              ";display:flex;flex-direction:row;gap:4px;width:max-content;min-width:max-content;padding:6px";
          });
          await page.$eval(".acpmux-mp-rail-scroll", (rail) => {
            const node = rail as HTMLElement;
            const container = node.parentElement!;
            const available = container.clientWidth;
            const cells = Math.max(1, Math.floor((available - 12 + 4) / 36));
            node.style.setProperty("width", `${cells * 36 - 4 + 12}px`, "important");
          });
          try {
            const cdp = await page.context().newCDPSession(page);
            await cdp.send("Emulation.setEmulatedMedia", {
              features: [{ name: "prefers-reduced-transparency", value: "reduce" }],
            });
          } catch {
            // WebKit has no CDP media override; the app attribute below still exercises the same rule.
          }
          await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", "true"));
          const edgeHits = async (side: "start" | "end") => {
            await page.$eval(
              ".acpmux-mp-rail-viewport",
              (node, position) => {
                const viewport = node as HTMLElement;
                viewport.scrollLeft = position === "start" ? 0 : viewport.scrollWidth;
              },
              side,
            );
            await page.waitForFunction((position) => {
              const viewport = document.querySelector<HTMLElement>(".acpmux-mp-rail-viewport");
              if (!viewport) return false;
              const expected = position === "start" ? 0 : viewport.scrollWidth - viewport.clientWidth;
              return Math.abs(viewport.scrollLeft - expected) < 1;
            }, side);
            return page.$eval(".acpmux-mp-rail-viewport", (node) => {
              const viewport = node as HTMLElement;
              const box = viewport.getBoundingClientRect();
              const points = [box.left + 1, box.right - 1];
              return {
                mask: getComputedStyle(viewport).maskImage,
                clip: getComputedStyle(viewport).clipPath,
                hits: points.map(
                  (x) =>
                    document
                      .elementFromPoint(x, box.top + box.height / 2)
                      ?.closest(".acpmux-mp-rail-tab")
                      ?.getAttribute("data-tab-index") ?? null,
                ),
              };
            });
          };
          for (const side of ["start", "end"] as const) {
            const result = await edgeHits(side);
            expect(result.mask).toBe("none");
            expect(result.clip).toContain("inset");
            expect(result.hits).toEqual([null, null]);
          }
          await page.close();
        }
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
            return {
              barRight: bar.right,
              right: rect.right,
              client: steer.clientWidth,
              scroll: steer.scrollWidth,
            };
          });
          expect(geometry.scroll).toBeLessThanOrEqual(geometry.client);
          expect(geometry.right).toBeLessThanOrEqual(geometry.barRight + 1);
          await page.close();
        }
      });
    });
  }
});
