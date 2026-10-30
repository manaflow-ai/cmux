// Leo, 2026-10-13 (coherence pass): the New Tab field should sit on a wallpaper theme as firmly as
// the art side's own chrome. Its box mixed the text color into the page background, which is
// transparent over a wallpaper, so the box was a thin film over the art (beige glass). Since #24593
// (2026-10-23) the box is the chat composer's shared glass: over art the theme's solid surface as a
// translucent tint (a surface, not a film; glass is never opaque), solid only under Reduce
// Transparency (composer-glass.test.ts holds the chat card to the same). Its suggestions are menu rows, the same height,
// corners and inset as every other menu in the pane. Focus is quiet (Lawrence 10-14): it keeps the
// box's rim and never takes the theme accent (newtab-quiet-focus.test.ts).
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
    "ui/glass/glass.css",
    "ui/popupSurface.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/composerStates.css",
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
  const body = `<div class="acpmux-shell"><div class="nt-screen"><div class="nt-composer"><div class="ui-glass ui-glass-floats nt-box"><div class="nt-input">
<textarea class="nt-field" rows="1" data-focus-ring="none" placeholder="Search or type a URL"></textarea></div></div></div></div></div>
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

      // Over a wallpaper the host marks the page see-through (data-cmux-see-through), under Plain glass.
      const open = async (accent: string, attributes = "") => {
        const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });
        await page.setContent(
          `<!doctype html><html data-cmux-see-through data-glass="plain" ${attributes} style="${theme(accent)}"><head><style>${css}</style></head><body>${body}</body></html>`,
        );
        return page;
      };

      test("the box is the composer's glass over the art: a surface, not a film, never opaque", async () => {
        const page = await open(TEXT);
        const background = await page.$eval(".nt-box", (node) => getComputedStyle(node).backgroundColor);
        expect(alpha(background), "a surface, not a film").toBeGreaterThanOrEqual(0.4);
        expect(alpha(background), "glass, never opaque").toBeLessThan(1);
        await page.close();
      });

      test("under Reduce Transparency the box is the theme's solid surface", async () => {
        const page = await open(TEXT, "data-reduce-transparency");
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

      test("focus stays quiet: the theme accent does not color the box", async () => {
        const edge = async (accent: string) => {
          const page = await open(accent);
          await page.focus(".nt-field");
          const shadow = await page.$eval(".nt-box", (node) => getComputedStyle(node).boxShadow);
          await page.close();
          return shadow;
        };
        expect(await edge(IRIS)).toBe(await edge(TEXT));
      });
    });
  }
});
