// Keyboard focus on a row of a menu, list or palette shows as a tint one step past hover, never a
// ring: no outline, and the same tint a highlighted row gets, whether the keyboard or the pointer
// put it there. Buttons and fields keep the ring. An optional left bar in the theme accent
// (`--cmux-row-focus-bar`) is off by default.
//
// The page is the real stylesheets plus markup in the shape the components render. The engines
// come from `playwright install chromium webkit`; where they are not installed, the cases are
// skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("row-focus.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "ui/ui.css"]
    .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
    .join("\n");

  // The agent pane: desktop.css first, then the pane's own sheets (agent-session/acpmux/main.tsx),
  // then the question card's own, which its component imports (a4eff4c722b2 moved its rows there).
  const paneCss = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/question/questionCard.css",
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
      console.warn(`row-focus: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  // Rose Pine with appearance.accent: theme, so the selection token is an iris tint.
  const IRIS = "rgb(196, 167, 231)";
  const HOST = `--cmux-text:rgb(224,222,244);--cmux-hover:rgba(224,222,244,0.06);--cmux-selection:rgba(196,167,231,0.26);--cmux-accent:${IRIS}`;
  const pageWith = (extra = "") => `<!doctype html><html style="${HOST};${extra}"><head><style>${css}</style></head>
<body style="background:rgb(25,23,36)">
<button class="ui-button" id="button">Done</button>
<div class="ui-popup" role="menu">
  <div class="ui-menu-item" role="menuitem" tabindex="0" id="row">Rename</div>
  <div class="ui-menu-item" role="menuitem" tabindex="-1" data-highlighted id="pointed">Duplicate</div>
</div>
</body></html>`;

  for (const [name, engine] of engines) {
    describe(`row focus in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      const style = (page: Page, id: string) =>
        page.$eval(`#${id}`, (node) => {
          const computed = getComputedStyle(node);
          return {
            outline: computed.outlineStyle,
            background: computed.backgroundColor,
            image: computed.backgroundImage,
            shadow: computed.boxShadow,
          };
        });

      test("a keyboard-focused row is tinted, with no ring; a button keeps its ring", async () => {
        const page = await browser.newPage();
        await page.setContent(pageWith());
        await page.keyboard.press("Tab");
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("button");
        expect((await style(page, "button")).outline).toBe("solid");
        await page.keyboard.press("Tab");
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("row");
        const row = await style(page, "row");
        expect(row.outline).toBe("none");
        // The tint is laid over the row's fill: the same color a highlighted row is painted, not
        // the accent's selection tint.
        const pointed = (await style(page, "pointed")).background;
        expect(pointed).not.toBe("rgba(0, 0, 0, 0)");
        expect(row.image).toContain(pointed);
        expect(row.image).not.toContain("196");
        // The bar is off: no shadow, or one whose every length is zero.
        expect(row.shadow === "none" || !/[1-9]/.test(row.shadow.replace(/rgba?\([^)]*\)/g, ""))).toBe(true);
        await page.close();
      });

      const look = (page: Page, selector: string) =>
        page.$eval(selector, (node) => {
          const computed = getComputedStyle(node);
          return `${computed.backgroundColor} ${computed.backgroundImage} ${computed.outlineStyle}`;
        });

      test("a checked question row still shows the keyboard highlight", async () => {
        const page = await browser.newPage();
        const row = (id: string, highlighted: boolean) =>
          `<button class="acpmux-question-row" role="checkbox" aria-checked="true" data-focus-ring="row" id="${id}"${highlighted ? " data-highlighted" : ""}>Option</button>`;
        await page.setContent(`<!doctype html><html style="${HOST}"><head><style>${paneCss}</style></head><body>
<div class="acpmux-shell">${row("checked", false)}${row("checked-highlighted", true)}</div>
</body></html>`);
        expect(await look(page, "#checked-highlighted")).not.toBe(await look(page, "#checked"));
        await page.close();
      });

      test("in the agent pane a keyboard-focused highlighted menu row has no ring", async () => {
        // The pane loads desktop.css but not ui.css, so nothing else removes the engine's own
        // focus ring (macOS WebKit draws it in the system blue) from the row a menu opens on.
        const page = await browser.newPage();
        await page.setContent(`<!doctype html><html style="${HOST}"><head><style>${paneCss}</style></head><body>
<div class="acpmux-shell"><div class="ui-popup" role="menu">
  <div class="ui-menu-item" role="menuitemradio" aria-checked="true" tabindex="0" data-highlighted id="medium">Medium</div>
</div></div>
</body></html>`);
        await page.keyboard.press("Tab");
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("medium");
        expect((await look(page, "#medium")).endsWith(" none")).toBe(true);
        await page.close();
      });

      test("a list container without an always-highlighted row keeps its ring; one with it does not", async () => {
        const page = await browser.newPage();
        await page.setContent(`<!doctype html><html style="${HOST}"><head><style>${css}</style></head><body>
<div role="listbox" tabindex="0" id="list" style="outline:none"><div role="option" class="selected">One</div></div>
<div role="menu" tabindex="0" data-focus-ring="rows" id="menu"><div role="menuitem" data-highlighted>One</div></div>
</body></html>`);
        await page.keyboard.press("Tab");
        expect((await look(page, "#list")).endsWith(" solid")).toBe(true);
        await page.keyboard.press("Tab");
        expect(await page.evaluate(() => document.activeElement?.id)).toBe("menu");
        expect((await look(page, "#menu")).endsWith(" none")).toBe(true);
        await page.close();
      });

      test("under Increase Contrast a focused row still gets the ring", async () => {
        const page = await browser.newPage();
        await page.emulateMedia({ contrast: "more" });
        await page.setContent(pageWith());
        await page.keyboard.press("Tab");
        await page.keyboard.press("Tab");
        expect((await style(page, "row")).outline).toBe("solid");
        await page.close();
      });

      test("the accent bar is an option: --cmux-row-focus-bar draws it in the theme accent", async () => {
        const page = await browser.newPage();
        await page.setContent(pageWith("--cmux-row-focus-bar:2px"));
        await page.keyboard.press("Tab");
        await page.keyboard.press("Tab");
        expect((await style(page, "row")).shadow).toContain(IRIS);
        expect((await style(page, "pointed")).shadow).toContain(IRIS);
        await page.close();
      });
    });
  }
});
