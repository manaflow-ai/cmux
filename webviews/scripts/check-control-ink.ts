// Measure the actual rendered control while the pointer moves, presses and releases.
// Run from webviews with bun scripts/check-control-ink.ts. FAST_CHECKS_OUT keeps each sampled frame.
import assert from "node:assert/strict";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { chromium, type Locator, type Page } from "playwright";
import { PNG } from "pngjs";

const webviews = path.resolve(import.meta.dir, "..");
const read = (name: string) => Bun.file(path.join(webviews, name)).text();
const build = await Bun.build({
  entrypoints: [path.join(webviews, "test/browser/control-ink.harness.tsx")],
  define: { "process.env.NODE_ENV": '"production"' },
});
assert(build.success, build.logs.join("\n"));
const js = await build.outputs[0]!.text();
const sheets = await Promise.all(["src/pages/shared/desktop.css", "src/ui/controls.css", "src/kit/kit.css"].map(read));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM_EXECUTABLE_PATH });
const errors: string[] = [];
const output = process.env.FAST_CHECKS_OUT;
if (output) await mkdir(output, { recursive: true });

async function sample(page: Page, control: Locator, label: string, expected: number, light: boolean) {
  const box = (await control.boundingBox())!;
  const bytes = await page.screenshot();
  const png = PNG.sync.read(bytes);
  const x = Math.floor(box.x + 8),
    y = Math.floor(box.y + box.height / 2);
  const value = png.data[(y * png.width + x) * 4]!;
  const actual = ((light ? 255 - value : value) * 100) / 255;
  if (output) await writeFile(path.join(output, label + ".png"), bytes);
  console.log(`${label} pixel ${value} ink ${actual.toFixed(2)}% (expected ${expected}%)`);
  // Two 8-bit alpha compositing steps can differ by one code value apiece.
  if (Math.abs(actual - expected) > 0.8) errors.push(`${label}: ${actual.toFixed(2)} vs ${expected}`);
}

try {
  for (const theme of ["light", "dark"] as const) {
    const light = theme === "light";
    for (const base of ["pane", "frame", "glass"] as const) {
      const page = await browser.newPage({ viewport: { width: 240, height: 140 }, colorScheme: theme });
      const paper = light ? "white" : "black",
        ink = light ? "black" : "white";
      const ground = base === "frame" ? 4 : 0;
      const label = `${theme}-${base}`;
      await page.setContent(
        `<div data-ink-base="frame"><main ${base === "glass" ? 'class="ui-glass"' : `data-ink-base="${base}"`}></main></div>`,
      );
      await page.addStyleTag({ content: sheets.join("\n").replaceAll(/^@import[^;]+;/gm, "") });
      await page.addStyleTag({
        content: `
        :root {color-scheme:${theme}; --ds-color-fg:${ink}; --ds-surface-ink:${ink}; --cmux-text:${ink};}
        body {margin:0;padding:12px;background:${paper}}
        main {display:grid;gap:8px;background:color-mix(in srgb,${ink} ${ground}%,${paper});}
        main ul {padding:0;margin:0}
        main button {height:36px; transition:none !important}
        /* Leave an empty sample strip on both controls, independent of label glyphs. */
        main .kit-row {padding-inline:28px}
      `,
      });
      await page.addScriptTag({ content: js });
      const button = page.getByRole("button", { name: "Options" });
      const row = page.getByRole("button", { name: "Session" });
      await button.waitFor();
      await sample(page, button, label + "-rest", ground, light);
      await button.hover();
      await sample(page, button, label + "-hover", 8, light);
      await page.mouse.down();
      await sample(page, button, label + "-held", 16, light);
      await page.mouse.up();
      await page.waitForFunction(() => document.querySelector("button")?.getAttribute("aria-expanded") === "true");
      await sample(page, button, label + "-open", 12, light);
      await page.mouse.down();
      await sample(page, button, label + "-open-held", 16, light);
      await page.mouse.up();
      await row.click();
      await row.locator("..").locator("[data-selected]").waitFor();
      await sample(page, row, label + "-selected", 12, light);
      await page.mouse.down();
      await sample(page, row, label + "-selected-held", 16, light);
      await page.mouse.up();
      await page.close();
    }
  }
} finally {
  await browser.close();
}
assert.deepEqual(errors, []);
