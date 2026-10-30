// The real transcript controls share a trailing chevron column through hover, keyboard focus,
// nested expansion and a Shell block's own Copy. The obsolete floating row Copy is not a fixture.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir, writeFile } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-transcript-chevron-column.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-transcript-chevron-column: skipping (run `bunx playwright install chromium`)");
    return;
  }
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.transcript-chevron-column", { browser, params: { variant: "shipped" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const width of [760, 420]) {
    test(`pins chevrons at the same x edge at ${width}px`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width, height: 640 }, reducedMotion: "reduce" });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.transcript-chevron-column", { variant: "shipped" })}`,
      );
      await page.locator("[data-chevron-column]").waitFor({ state: "attached" });
      const before = await page
        .locator("[data-chevron-column] .cv-tool__chevron")
        .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().right * 10) / 10));
      expect(before).toHaveLength(5);
      const command = page.locator('[data-label="command"] .cv-command');
      await command.hover();
      await command.focus();
      const after = await page
        .locator("[data-chevron-column] .cv-tool__chevron")
        .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().right * 10) / 10));
      expect(new Set(before).size).toBe(1);
      expect(after).toEqual(before);
      const action = await command.evaluate((row) => {
        const meta = row.querySelector(".cv-command__meta")!.getBoundingClientRect();
        const chevron = row.querySelector(".cv-tool__chevron")!.getBoundingClientRect();
        return { meta: meta.toJSON(), chevron: chevron.toJSON() };
      });
      expect(action.meta.right).toBeLessThan(action.chevron.left);
      await command.click();
      const copy = page.locator('[data-label="command"] .cv-shell__actions button[aria-label="Copy"]');
      await copy.waitFor();
      await copy.hover();
      await copy.focus();
      await page.locator('[data-label="group"] > .cv-tools > button').click();
      await page.locator('[data-label="run"] > .cv-tools > button').click();
      await page.locator('[data-label="thought"] .cv-thought').click();
      const expanded = await page
        .locator("[data-chevron-column] .cv-tool__chevron")
        .evaluateAll((nodes) => nodes.map((node) => Math.round(node.getBoundingClientRect().right * 10) / 10));
      expect(expanded).toHaveLength(9);
      expect(new Set(expanded)).toEqual(new Set(before));
      expect(await page.locator("[data-chevron-column] .acpmux-row__copy").count()).toBe(0);
      if (process.env.CMUX_CHEVRON_ARTIFACT_DIR) {
        const directory = process.env.CMUX_CHEVRON_ARTIFACT_DIR;
        await mkdir(directory, { recursive: true });
        await writeFile(
          path.join(directory, `rects-${width}.json`),
          JSON.stringify({ width, before, after, expanded, action }, null, 2),
        );
        await page.screenshot({ path: path.join(directory, `chevrons-${width}.png`), fullPage: true });
      }
      await page.close();
    });
  }
});
