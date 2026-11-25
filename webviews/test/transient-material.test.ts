// Shared adoption retains the standalone cascade and the accessibility fallback.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transient-material.test.ts", async () => {
  const css = (file: string) =>
    readFileSync(new URL(`../src/${file}`, import.meta.url), "utf8").replace(/^@import .*$/gm, "");
  const base = ["pages/shared/desktop.css", "ui/popupSurface.css", "ui/glass/glass.css", "ui/notice.css"]
    .map(css)
    .join("\n");
  let browser: Browser;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
  });

  for (const scheme of ["light", "dark"] as const) {
    test(`material is scoped and accessible in ${scheme}`, async () => {
      const page = await browser.newPage({ colorScheme: scheme });
      try {
        await page.setContent(`<html style="--cmux-surface-solid:rgb(70,80,90);--cmux-popup-surface:rgb(85,95,105);--cmux-text:rgb(245,245,245);color-scheme:${scheme}">
        <head><style>${base}</style></head><body>
        <div class="ui-popup ui-glass">Menu</div><div class="ui-dialog ui-glass">Sheet</div>
        <div class="ui-tooltip ui-glass">Tooltip</div><div class="ui-notice ui-glass">Toast</div>
        </body></html>`);
        const read = () =>
          page.locator(".ui-glass").evaluateAll((nodes) =>
            nodes.map((node) => {
              const style = getComputedStyle(node);
              return { background: style.backgroundColor, backdrop: style.backdropFilter };
            }),
          );
        const held = await read();
        await page.addStyleTag({ content: css("pages/shared/transientMaterial.css") });
        expect(await read()).toEqual(held);
        await page.evaluate(() => {
          document.documentElement.dataset.transientMaterial = "standard";
        });
        const selected = await read();
        expect(selected).toEqual(held);
        expect(selected[1].backdrop).toContain("blur(32px)");
        expect(selected[2].backdrop).toContain("blur(32px)");
        await page.evaluate(() => {
          document.documentElement.dataset.reduceTransparency = "";
        });
        const reduced = await read();
        for (const sample of reduced) {
          expect(sample.backdrop).toBe("none");
          expect(sample.background).toMatch(/^rgb\(/);
        }
        await page.evaluate(() => {
          delete document.documentElement.dataset.reduceTransparency;
        });
        expect(await read()).toEqual(selected);
      } finally {
        await page.close();
      }
    });
  }
});
