// First-party pages take their accent and status colors from the host theme, not from macOS or
// fixed hex values: native checkboxes and sliders, Settings' danger and warning text, destructive
// menu items, and the diff view's focus accent and primary comment button. The host sends
// `--cmux-accent` as the text color under the default neutral accent, so the default stays free
// of system blue; with `appearance.accent` set it's the theme's hue.
//
// The page is the real stylesheets with the variables the host sets (Rose Pine here). The engines
// come from `playwright install chromium webkit`; where they are not installed, the cases are
// skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("page-theme-colors.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const css = ["pages/shared/desktop.css", "pages/settings/styles.css", "ui/ui.css", "styles.css"]
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
      console.warn(`page-theme-colors: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  // Rose Pine, as the host sends it with appearance.accent: theme.
  const IRIS = "rgb(196, 167, 231)";
  const ON_ACCENT = "rgb(25, 23, 36)";
  const LOVE = "rgb(235, 111, 146)";
  const GOLD = "rgb(246, 193, 119)";
  const HOST = `--cmux-text:rgb(224,222,244);--cmux-accent:${IRIS};--cmux-on-accent:${ON_ACCENT};--cmux-app-danger:${LOVE};--cmux-app-warning:${GOLD}`;
  const PAGE = `<!doctype html><html style="${HOST}"><head><style>${css}</style></head><body>
<input type="checkbox" checked id="check">
<span id="danger" style="color:var(--danger)">Failed</span>
<span id="warning" style="color:var(--warning)">Needs restart</span>
<div class="ui-menu-item ui-menu-item-destructive" id="destructive">Delete</div>
<button class="comment-button comment-button-primary" id="primary">Comment</button>
</body></html>`;

  for (const [name, engine] of engines) {
    describe(`page theme colors in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      test("controls, status text, destructive items and the diff's primary button follow the host theme", async () => {
        const page = await browser.newPage();
        await page.setContent(PAGE);
        const style = (id: string, property: string) =>
          page.$eval(`#${id}`, (node, key) => getComputedStyle(node).getPropertyValue(key), property);
        expect(await style("check", "accent-color")).toBe(IRIS);
        expect(await style("danger", "color")).toBe(LOVE);
        expect(await style("warning", "color")).toBe(GOLD);
        expect(await style("destructive", "color")).toBe(LOVE);
        expect(await style("primary", "background-color")).toBe(IRIS);
        expect(await style("primary", "color")).toBe(ON_ACCENT);
        await page.close();
      });
    });
  }
});
