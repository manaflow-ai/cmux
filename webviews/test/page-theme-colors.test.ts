// First-party pages take their accent from the host theme, not from macOS or fixed hex values:
// native checkboxes and sliders, and the diff view's focus accent and primary comment button.
// The host sends `--cmux-accent` as the text color under the default neutral accent, so the
// default stays free of system blue; with `appearance.accent` set it's the theme's hue.
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
  const css = ["pages/shared/desktop.css", "styles.css"]
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
  const TEXT = "rgb(224, 222, 244)";
  const pageWith = (
    accent: string,
  ) => `<!doctype html><html style="--cmux-text:${TEXT};--cmux-accent:${accent};--cmux-on-accent:${ON_ACCENT};--cmux-diff-bg:rgb(25,23,36);--cmux-diff-fg:${TEXT}"><head><style>${css}</style></head><body>
<input type="checkbox" checked id="check">
<button class="comment-button comment-button-primary" id="primary">Comment</button>
</body></html>`;

  for (const [name, engine] of engines) {
    describe(`page theme colors in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      test("checkboxes and the diff's primary button follow the host accent", async () => {
        const page = await browser.newPage();
        await page.setContent(pageWith(IRIS));
        const style = (id: string, property: string) =>
          page.$eval(`#${id}`, (node, key) => getComputedStyle(node).getPropertyValue(key), property);
        expect(await style("check", "accent-color")).toBe(IRIS);
        expect(await style("primary", "background-color")).toBe(IRIS);
        expect(await style("primary", "color")).toBe(ON_ACCENT);
        await page.close();
      });

      test("under the neutral accent the primary button still shows its hover", async () => {
        const page = await browser.newPage();
        await page.setContent(pageWith(TEXT));
        const background = () => page.$eval("#primary", (node) => getComputedStyle(node).backgroundColor);
        const rest = await background();
        await page.hover("#primary");
        expect(await background()).not.toBe(rest);
        await page.close();
      });
    });
  }
});
