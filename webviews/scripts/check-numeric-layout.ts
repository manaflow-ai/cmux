// Manual browser regression; not registered in CI. Run via cmux-ci test --setup playwright.
import assert from "node:assert/strict";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Page } from "playwright";
import { createServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "../test/support/galleryFrame";

type Scene = {
  entry: string;
  variant: string;
  selectors: string[];
  prepare?: (page: Page) => Promise<void>;
};
const scenes: Scene[] = [
  { entry: "agent-pane.home-lists", variant: "baseline", selectors: [".acpmux-home-meta"] },
  {
    entry: "agent-pane.chat-inspector",
    variant: "full",
    selectors: [".acpmux-chat-inspector-fold", ".acpmux-chat-inspector-subagents__ended .acpmux-summary-text"],
  },
  {
    entry: "agent-pane.chat-inspector",
    variant: "workflow-mixed",
    selectors: [".acpmux-workflow-tasks__group"],
  },
  {
    entry: "pages.settings",
    variant: "play-reset-number",
    selectors: [".number", ".number-sizer", ".number-sizer::after"],
    prepare: async (page) => {
      const input = page.locator('[data-row-key="layout.defaultColumnWidth"] input.number');
      await input.scrollIntoViewIfNeeded();
      const widths: number[] = [];
      for (const value of ["11111111", "88888888", "00000000"]) {
        await input.fill(value);
        const box = await input.boundingBox();
        assert.ok(box, "number field must remain visible while typing");
        widths.push(box.width);
      }
      assert.ok(Math.max(...widths) - Math.min(...widths) <= 0.5, `equal-length input shifted: ${widths.join(", ")}`);
    },
  },
  {
    entry: "pages.settings",
    variant: "theme",
    selectors: [".theme-count"],
    prepare: async (page) => {
      await page.locator("[data-theme-picker]").first().click();
    },
  },
  {
    entry: "pages.settings.theme-tokens",
    variant: "default",
    selectors: [".token-tuner-contrast"],
    prepare: async (page) => {
      await page.locator('[data-token="foreground"]').click();
    },
  },
  {
    entry: "agent-pane.diff-panel",
    variant: "review-file",
    selectors: [".acpmux-revert-count"],
    prepare: async (page) => {
      if ((await page.locator(".acpmux-revert-count").count()) === 0) {
        await page.getByRole("button", { name: "More actions for src/agent/Reply.tsx", exact: true }).click();
        await page.getByRole("menuitem", { name: "Reject file", exact: true }).click();
      }
    },
  },
];
const output = process.env.NUMERIC_LAYOUT_ARTIFACTS ?? "artifacts/numeric-layout";
await mkdir(output, { recursive: true });
const vite = await createServer({
  root: process.cwd(),
  configFile: path.resolve("vite.config.ts"),
  server: { host: "127.0.0.1", port: 0 },
  logLevel: "error",
});
await vite.listen();
const browser = await chromium.launch();
const failures: string[] = [];
try {
  await warmGalleryFrame(vite, [...new Set(scenes.map((scene) => scene.entry))], {
    browser,
    timeoutMs: 300_000,
  });
  const port = (vite.httpServer!.address() as { port: number }).port;
  for (const colorScheme of ["light", "dark"] as const) {
    for (const width of [480, 1000]) {
      for (const scene of scenes) {
        const name = `${scene.entry}-${scene.variant}-${colorScheme}-${width}`;
        const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme });
        try {
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(scene.entry, { variant: scene.variant, colorScheme, reducedMotion: "true" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await scene.prepare?.(page);
          for (const selector of scene.selectors) {
            const [element, pseudo] = selector.split("::");
            const locator = page.locator(element!);
            assert.ok((await locator.count()) > 0, `${selector} must render`);
            const features = await locator.evaluateAll(
              (nodes, pseudoElement) => nodes.map((node) => getComputedStyle(node, pseudoElement).fontVariantNumeric),
              pseudo ? `::${pseudo}` : null,
            );
            assert.ok(
              features.every((value) => value.includes("tabular-nums")),
              `${selector}: ${features.join(", ")}`,
            );
          }
          console.log(`PASS ${name}`);
        } catch (error) {
          failures.push(`${name}: ${String(error)}`);
          console.error(`FAIL ${failures.at(-1)}`);
        } finally {
          await page.screenshot({ path: path.join(output, `${name}.png`), fullPage: true });
          await page.close();
        }
      }
    }
  }
} finally {
  await browser.close();
  await vite.close();
}
assert.equal(failures.length, 0, failures.join("\n"));
