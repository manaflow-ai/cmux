// cmux-web-test-timeout: 120
// Source-level and Chromium computed-style evidence for HQ #6236 brief 24.
// The host has TWO knobs: app.uiScale applies WKWebView.pageZoom; the separate
// --cmux-interface-scale is Typography.userScale (chrome size and font override).
// Check actual CSS variables and shared controls at the supported chrome scales.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { compile } from "@tailwindcss/node";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("design-scale-parity.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const src = path.resolve(import.meta.dir, "../src");
  const desktop = fs.readFileSync(path.join(src, "pages/shared/desktop.css"), "utf8");
  const controls = fs.readFileSync(path.join(src, "ui/controls.css"), "utf8");
  const theme = fs.readFileSync(path.join(src, "ui/theme.generated.css"), "utf8");
  let browser: Browser | undefined;

  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  test("real generated CSS: shared tokens and grid agree across effective typography scale", async () => {
    const input = `@import "tailwindcss/theme.css" layer(theme);\n@import "tailwindcss/utilities.css" layer(utilities);\n${theme}`;
    const compiler = await compile(input, { base: src, onDependency: () => {} });
    const utilities = compiler.build(["p-3", "p-6"]);
    const page = await browser!.newPage({ viewport: { width: 900, height: 650 } });
    try {
      await page.setContent(`<!doctype html><html lang="en"><head></head><body>
        <div id="tw3" class="p-3">Tailwind 12</div>
        <div id="ds3" style="padding:var(--ds-space-3)">Named 12</div>
        <div id="tw6" class="p-6">Tailwind 24</div>
        <div id="ds5" style="padding:var(--ds-space-5)">Named 24</div>
        <div id="grid" style="height:var(--grid-row)"></div>
        <button type="button" class="ui-button ui-btn" data-size="md">
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M0 0L16 16"/></svg>
          Run
        </button>
        </body></html>`);
      await page.addStyleTag({ content: desktop });
      await page.addStyleTag({ content: controls });
      await page.addStyleTag({ content: utilities });

      for (const themeName of ["light", "dark"] as const) {
        // 1.5 is an *effective* Typography.userScale from font override × Debug
        // interface size, not a selectable 150% chrome interface-size preset.
        for (const scale of [1, 1.125, 1.25, 1.5]) {
          // DesignSettings.interfaceScaleScript injects this as Typography.userScale.
          // It independently injects --cmux-ui-scale for page zoom; that is NOT this scale.
          const measured = await page.evaluate(({ themeName, scale }) => {
            const root = document.documentElement;
            root.dataset.theme = themeName;
            root.style.setProperty("--cmux-interface-scale", String(scale));
            root.style.setProperty("--cmux-ui-scale", "1.5");
            const el = (id: string) => document.getElementById(id)!;
            const px = (value: string) => Number.parseFloat(value);
            const button = document.querySelector<HTMLButtonElement>(".ui-btn")!;
            const css = getComputedStyle(button);
            return {
              tailwind12: px(getComputedStyle(el("tw3")).paddingLeft),
              named12: px(getComputedStyle(el("ds3")).paddingLeft),
              tailwind24: px(getComputedStyle(el("tw6")).paddingLeft),
              named24: px(getComputedStyle(el("ds5")).paddingLeft),
              row: el("grid").getBoundingClientRect().height,
              control: button.getBoundingClientRect().height,
              glyph: button.querySelector("svg")!.getBoundingClientRect().width,
              radius: px(css.borderTopLeftRadius),
              lineHeight: px(css.lineHeight),
            };
          }, { themeName, scale });
          expect(measured.tailwind12).toBeCloseTo(12 * scale, 1);
          expect(measured.named12).toBeCloseTo(measured.tailwind12, 1);
          // The token suffix 5 means 24px; its Tailwind peer is p-6.
          expect(measured.tailwind24).toBeCloseTo(24 * scale, 1);
          expect(measured.named24).toBeCloseTo(measured.tailwind24, 1);
          expect(measured.row).toBeCloseTo(28 * scale, 1);
          expect(measured.control).toBeCloseTo(measured.row, 1);
          expect(measured.glyph).toBeCloseTo(16 * scale, 1);
          expect(measured.radius).toBeCloseTo(6 * scale, 1);
          expect(measured.lineHeight).toBeCloseTo(18 * scale, 1);
        }
      }
      // pageZoom is independent: changing its host metadata alone leaves CSS
      // values alone. WebKit applies the visual page zoom outside CSS.
      const before = await page.locator(".ui-btn").evaluate((el) => el.getBoundingClientRect().height);
      await page.evaluate(() => document.documentElement.style.setProperty("--cmux-ui-scale", "0.85"));
      const after = await page.locator(".ui-btn").evaluate((el) => el.getBoundingClientRect().height);
      expect(after).toBeCloseTo(before, 1);
    } finally {
      await page.close();
    }
  });
});
