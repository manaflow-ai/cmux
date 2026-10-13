// Leo, 2026-10-13 (coherence pass): the New Tab field should sit on a wallpaper theme as firmly as
// the art side's own chrome. Its box mixed the text color into the page background, which is
// transparent over a wallpaper, so the box was a thin film over the art (beige glass). It is the
// theme's own solid surface under the same tint. Its suggestions are menu rows, the same height,
// corners and inset as every other menu in the pane, and focus takes one step toward the theme
// accent rather than toward the text color.
//
// The page is the pane's real stylesheets plus markup in the shape NewTabScreen renders. The
// engines come from `playwright install chromium webkit`; where they are not installed, the cases
// are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-field-on-art.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "ui/popupSurface.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/newtab/screen.css",
  ]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8").replace(/^@import .*$/gm, ""))
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
      console.warn(`new-tab-field-on-art: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  // Rose Pine over a wallpaper: the page background is see-through; the surface stays solid.
  const TEXT = "rgb(224, 222, 244)";
  const IRIS = "rgb(196, 167, 231)";
  const theme = (accent: string) =>
    [
      `--agent-text:${TEXT}`,
      `--agent-accent:${accent}`,
      "--agent-accent-text:rgb(25, 23, 36)",
      "--agent-page-bg:transparent",
      "--cmux-surface-background:rgba(25, 23, 36, 0)",
      "--cmux-surface-solid:rgb(25, 23, 36)",
      "--cmux-popup-surface:rgb(52, 49, 68)",
    ].join(";");
  const body = `<div class="acpmux-shell"><div class="nt-screen"><div class="nt-box"><div class="nt-input">
<input class="nt-field" data-focus-ring="none" placeholder="Search or type a URL"></div></div></div></div>
<div class="ui-positioner"><div class="ui-popup nt-popover"><div class="nt-rows" id="rows">
<div class="nt-row is-selected" id="row">reddit.com</div></div></div></div>
<div class="ui-positioner"><div class="ui-popup ui-context-menu" id="menu"><div class="ui-menu-item" id="item">Copy</div></div></div>
<div class="acpmux-shell"><div class="acpmux-newtab"><div style="position:relative"><div class="acpmux-omni" id="omni">
<div class="acpmux-omni-row is-selected" id="omni-row">reddit.com</div></div></div></div></div>`;

  // The alpha of a computed color, in either engine's serialization.
  const alpha = (color: string) => {
    const slash = color.match(/\/\s*([\d.]+)\s*\)$/);
    if (slash) return Number(slash[1]);
    const rgba = color.match(/^rgba\((?:[^,]+,){3}\s*([\d.]+)\)$/);
    return rgba ? Number(rgba[1]) : 1;
  };

  for (const [name, engine] of engines) {
    describe(`the New Tab field on a wallpaper theme in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      const open = async (accent: string) => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
        await page.setContent(
          `<!doctype html><html style="${theme(accent)}"><head><style>${css}</style></head><body>${body}</body></html>`,
        );
        return page;
      };

      test("the box is the theme's solid surface, not a film over the art", async () => {
        const page = await open(TEXT);
        const background = await page.$eval(".nt-box", (node) => getComputedStyle(node).backgroundColor);
        expect(alpha(background)).toBe(1);
        await page.close();
      });

      test("a suggestion row is a menu row: the same height, corners and inset", async () => {
        const page = await open(TEXT);
        const metrics = (row: string, list: string) =>
          page.evaluate(
            ([row, list]) => {
              const r = getComputedStyle(document.querySelector(row)!);
              const l = getComputedStyle(document.querySelector(list)!);
              return { height: r.height, radius: r.borderTopLeftRadius, inset: l.paddingTop };
            },
            [row, list],
          );
        expect(await metrics("#row", "#rows")).toEqual(await metrics("#item", "#menu"));
        // The classic template's suggestions (NewTabPage's omnibar) are the same rows (batch 2).
        expect(await metrics("#omni-row", "#omni")).toEqual(await metrics("#item", "#menu"));
        const corner = (id: string) => page.$eval(id, (node) => getComputedStyle(node).borderTopLeftRadius);
        expect(await corner("#omni")).toBe(await corner("#menu"));
        await page.close();
      });

      test("focus takes a step toward the theme accent", async () => {
        const edge = async (accent: string) => {
          const page = await open(accent);
          await page.focus(".nt-field");
          const shadow = await page.$eval(".nt-box", (node) => getComputedStyle(node).boxShadow);
          await page.close();
          return shadow;
        };
        expect(await edge(IRIS)).not.toBe(await edge(TEXT));
      });
    });
  }
});
