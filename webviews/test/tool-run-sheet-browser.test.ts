// l10n-allow-file: browser fixtures and measurement diagnostics.
// Same harness on base/head: restore the changed production files from base, retain this test,
// its browser fixture and mixedToolRunFixture, and set TOOL_RUN_SHEET_BASELINE=1.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("tool-run-sheet-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const baseline = process.env.TOOL_RUN_SHEET_BASELINE === "1";
  const output = process.env.FAST_CHECKS_OUT;
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let gallery: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/tool-run-sheet.html");
    browser = await chromium.launch({ headless: true });
    if (output) await mkdir(output, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await gallery?.close();
    await vite?.close();
  });

  for (const theme of ["light", "dark"] as const)
    test(`${theme}: one disclosure reveals useful steps`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 760 }, deviceScaleFactor: 2 });
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/tool-run-sheet.html?theme=${theme}`);
        const fixture = page.locator("[data-sheet-fixture]");
        const summary = fixture.locator(".cv-tool.is-run");
        await summary.waitFor();
        expect(await fixture.locator(".cv-tool").count()).toBe(1);
        await summary.click();
        await fixture.locator(".cv-tool-run").waitFor();
        await page.evaluate(() => document.fonts.ready);
        const measured = await fixture.evaluate((root) => {
          const run = root.querySelector(".cv-tool-run")!;
          const rows = [...run.querySelectorAll(".cv-tool")];
          return {
            visibleRows: rows.length,
            redundantGroupHeaders: rows.filter((row) =>
              /^(?:Ran \d+ commands|Used \d+ tools)/.test(row.textContent?.trim() ?? ""),
            ).length,
            discoveryRows: rows.filter((row) => /ToolSearch|Loaded tools/.test(row.textContent ?? "")).length,
            expandedHeightPx: root.getBoundingClientRect().height,
            titles: rows.map((row) => row.textContent?.trim()),
          };
        });
        console.log(`TOOL_RUN_SHEET ${JSON.stringify({ baseline, theme, ...measured })}`);
        if (!baseline) {
          expect(measured.visibleRows).toBe(5);
          expect(measured.redundantGroupHeaders).toBe(0);
          expect(measured.discoveryRows).toBe(0);
          // A finished shell row says what it did (commandActions.ts commandSaid): `echo` is not in the
          // verb table, so the row reads as its description, not "Ran echo baseline".
          await fixture.getByRole("button", { name: /^Check the baseline/ }).click();
          expect(await fixture.textContent()).toContain("baseline passed");
          await fixture.getByRole("button", { name: "Find the retry handler" }).click();
          // An opened call is its arguments as labeled fields and its output (ToolDetail), never one JSON block.
          expect(await fixture.locator(".cv-tool-detail__key").allTextContents()).toContain("pattern");
          // Closed, the capture's screenshot is the small image at its row's edge; opened, the image
          // shows under the row (ToolImages) and the small one steps aside (Lucas, 2026-11-11).
          const edge = fixture.getByRole("img", { name: "Capture the repaired screen" });
          await edge.waitFor();
          await fixture.getByRole("button", { name: "Capture the repaired screen", exact: false }).click();
          const shot = fixture.locator(".cv-tool-images img").first();
          await shot.waitFor();
          await shot.evaluate((image) => (image as HTMLImageElement).decode());
          expect(await edge.count()).toBe(0);
          expect(await fixture.textContent()).not.toContain("Waiting…");
          expect(await fixture.textContent()).not.toContain('"pattern"');
        }
        if (output)
          await fixture.screenshot({
            path: path.join(output, `tool-sheet-${baseline ? "base" : "head"}-${theme}.png`),
          });
        expect(errors).toEqual([]);
      } finally {
        await page.close();
      }
    });

  if (!baseline)
    test("a clipped description-only step opens its full title without empty output", async () => {
      const page = await browser.newPage({ viewport: { width: 420, height: 760 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}/test/browser/tool-run-sheet.html?long=1`);
        await page.locator(".cv-tool.is-run").click();
        const step = page.getByRole("button", { name: /Read the retry context Read the retry context/ });
        await step.click();
        expect(await step.getAttribute("aria-expanded")).toBe("true");
        const fits = await step.locator(".cv-tool__text").evaluate((node) => node.scrollWidth <= node.clientWidth + 1);
        expect(fits).toBe(true);
        expect(await page.locator("[data-sheet-fixture]").textContent()).not.toContain("Waiting…");
      } finally {
        await page.close();
      }
    });

  if (!baseline)
    test("gallery comparisons: sheet, shared, guide and card", async () => {
      const entry = "agent-pane.claude-desktop-organization";
      gallery = await createServer({
        configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
        server: { port: 0, host: "127.0.0.1", strictPort: false },
        logLevel: "error",
      });
      await gallery.listen();
      await warmGalleryFrame(gallery, entry, { browser, params: { variant: "ios-sheet" } });
      const port = (gallery.httpServer!.address() as { port: number }).port;
      for (const variant of ["ios-sheet", "shared", "guide", "card"])
        for (const colorScheme of ["light", "dark"]) {
          const page = await browser.newPage({ viewport: { width: 760, height: 1100 }, deviceScaleFactor: 2 });
          try {
            await page.goto(
              `http://127.0.0.1:${port}` + galleryFrame(entry, { variant, colorScheme, frame: "component" }),
            );
            await page.waitForFunction(() =>
              ["1", "error"].includes(document.documentElement.dataset.galleryReady ?? ""),
            );
            expect(await page.locator("html").getAttribute("data-gallery-ready")).toBe("1");
            await page.locator(".cv-steps").waitFor();
            if (output)
              await page.screenshot({ path: path.join(output, `tool-gallery-${variant}-${colorScheme}.png`) });
          } finally {
            await page.close();
          }
        }
    });
});
