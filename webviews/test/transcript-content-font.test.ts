// l10n-allow-file: browser fixture labels and assertions.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import type { ViteDevServer } from "vite";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("transcript-content-font.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.transcript-type";
  const capture = process.env.CMUX_FONT_CAPTURE_DIR;
  const baseRoot = process.env.CMUX_FONT_BASE_ROOT;
  let vite: ViteDevServer;
  const browsers: { engine: string; browser: Browser }[] = [];
  beforeAll(async () => {
    const { createServer } = await import("vite");
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    for (const [engine, launcher] of Object.entries({ chromium, webkit }))
      browsers.push({ engine, browser: await launcher.launch({ headless: true }) });
    await warmGalleryFrame(vite, entry, { browser: browsers[0]!.browser });
    if (capture) await mkdir(capture, { recursive: true });
  });
  afterAll(async () => {
    await Promise.all(browsers.map(({ browser }) => browser.close()));
    await vite?.close();
  });

  const font = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .evaluate((node) => parseFloat(getComputedStyle(node).fontSize));
  const contained = (page: Page, selector: string) =>
    page.locator(selector).evaluateAll((nodes) =>
      nodes.map((node) => {
        const box = node.getBoundingClientRect();
        const range = document.createRange();
        const walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
        const overflow: string[] = [];
        for (let text = walker.nextNode(); text; text = walker.nextNode()) {
          if (!text.nodeValue?.trim()) continue;
          range.selectNodeContents(text);
          for (const glyph of range.getClientRects())
            if (glyph.top < box.top - 1 || glyph.bottom > box.bottom + 1) overflow.push(text.nodeValue);
        }
        return { selector: node.className, overflow };
      }),
    );

  for (const theme of ["light", "dark"])
    test(`${theme}: transcript text scales with intact headers and previews`, async () => {
      for (const { engine, browser } of browsers) {
        const page = await browser.newPage({ viewport: { width: 760, height: 1100 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "reading", theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".cv-footnotes").waitFor({ state: "attached" });
          await page.locator(".cv-diagram").scrollIntoViewIfNeeded();
          await page.locator(".cv-diagram__error").waitFor();
          const diffLine = page.locator(".cv-edit-diff__body [data-line]").first();
          await diffLine.waitFor({ state: "attached" });
          const defaultDiff = await diffLine.evaluate((node) => ({
            size: parseFloat(getComputedStyle(node).fontSize),
            line: parseFloat(getComputedStyle(node).lineHeight),
          }));
          if (process.env.CMUX_FONT_METRICS) console.log(JSON.stringify({ engine, theme, defaultDiff }));
          for (const size of [10, 14, 28]) {
            await page.evaluate(async (size) => {
              const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
              const { setChatDisplay } = await import(modulePath);
              setChatDisplay({ "agentPane.display.font.size": size });
            }, size);
            for (const [selector, base] of [
              [".cv-codeblock__header", 14],
              [".cv-edit-diff__header", 13],
              [".cv-shell__label", 13],
              [".cv-shell__body", 12],
              [".cv-shell__exit", 13],
              [".cv-tool-output", 12],
              [".cv-command__line", 12.5],
              [".cv-command__meta", 12],
              [".cv-code-plain", 12],
              [".cv-footnotes", 12.5],
              [".cv-turn-auth-action", 12],
              [".acpmux-shell-block-command", 12.5],
              [".acpmux-shell-block-output", 12],
              [".acpmux-render-card-title", 12.5],
              [".cv-diagram__bar", 11],
              [".cv-diagram__error", 12],
            ] as const)
              expect(await font(page, selector), `${engine} ${selector} at ${size}`).toBeCloseTo((base * size) / 14, 2);

            expect(await font(page, ".cv-edit-diff__body [data-line]"), `${engine} diff body at ${size}`).toBeCloseTo(
              size === 14 ? defaultDiff.size : (12 * size) / 14,
              2,
            );
            const diffHeight = await diffLine.evaluate((node) => parseFloat(getComputedStyle(node).lineHeight));
            expect(diffHeight, `${engine} diff line height at ${size}`).toBeCloseTo(
              size === 14 ? defaultDiff.line : (20 * size) / 14,
              2,
            );

            for (const [width, zoom] of [
              [760, 1],
              [390, 1.25],
            ] as const) {
              await page.setViewportSize({ width, height: 1100 });
              await page.evaluate((zoom) => {
                document.documentElement.style.zoom = String(zoom);
              }, zoom);
              if (size === 14 && width === 760) {
                for (const [selector, height] of [
                  [".cv-codeblock__header", 45.5],
                  [".cv-edit-diff__header", 32],
                  [".acpmux-shell-block-head", 32],
                  [".cv-diagram__bar", 28],
                ] as const)
                  expect(
                    await page
                      .locator(selector)
                      .first()
                      .evaluate((node) => node.getBoundingClientRect().height),
                    `default ${selector}`,
                  ).toBeCloseTo(height, 1);
              }
              const headers = await contained(
                page,
                ".cv-codeblock__header, .cv-edit-diff__header, .acpmux-shell-block-head, .cv-turn-actions, .cv-turn-auth-action, .cv-diagram__bar, .cv-command",
              );
              expect(
                headers.flatMap((row) => row.overflow),
                `${engine} ${size}px ${width} headers`,
              ).toEqual([]);
              expect((await contained(page, ".cv-edit-diff__body [data-line]")).flatMap((row) => row.overflow)).toEqual(
                [],
              );
              const diffPreview = await page.locator(".cv-edit-diff__body").evaluate((node) => node.clientHeight);
              expect(diffPreview, "eight scaled diff rows remain in the preview").toBeGreaterThanOrEqual(
                Math.floor(diffHeight * 8),
              );
              const previews = await page.locator(".cv-shell__body, .cv-tool-output").evaluateAll((nodes) =>
                nodes.map((node) => ({
                  height: node.clientHeight,
                  line: parseFloat(getComputedStyle(node).lineHeight),
                })),
              );
              for (const preview of previews)
                expect(preview.height, "eight scaled lines remain in the preview").toBeGreaterThanOrEqual(
                  Math.floor(preview.line * 8),
                );
              expect(
                await page
                  .locator(".acpmux-shell-block-head")
                  .evaluate((node) => node.scrollWidth <= node.clientWidth + 1),
              ).toBe(true);
              if (capture)
                await page.locator("main.acpmux-scroll").evaluate((node) => {
                  node.scrollTop = 0;
                });
              if (capture)
                await page.screenshot({
                  path: path.join(capture, `${engine}-${theme}-${size}-${width}.png`),
                });
            }
          }
          await page.getByRole("button", { name: "Open image", exact: true }).click();
          await page.locator(".acpmux-image-viewer-title").waitFor();
          for (const size of [10, 14, 28]) {
            await page.evaluate(async (size) => {
              const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
              const { setChatDisplay } = await import(modulePath);
              setChatDisplay({ "agentPane.display.font.size": size });
            }, size);
            for (const [width, zoom] of [
              [760, 1],
              [390, 1.25],
            ] as const) {
              await page.setViewportSize({ width, height: 1100 });
              await page.evaluate((zoom) => {
                document.documentElement.style.zoom = String(zoom);
              }, zoom);
              expect(await font(page, ".acpmux-image-viewer-title")).toBeCloseTo((13 * size) / 14, 2);
              expect((await contained(page, ".acpmux-image-viewer-bar")).flatMap((row) => row.overflow)).toEqual([]);
              expect(
                await page
                  .locator(".acpmux-image-viewer-bar")
                  .evaluate((node) => node.scrollWidth <= node.clientWidth + 1),
              ).toBe(true);
              if (size === 14 && width === 760)
                expect(
                  await page
                    .locator(".acpmux-image-viewer-bar")
                    .evaluate((node) => node.getBoundingClientRect().height),
                ).toBe(44);
              if (capture)
                await page.screenshot({ path: path.join(capture, `${engine}-${theme}-image-${size}-${width}.png`) });
            }
          }
        } finally {
          await page.close();
        }
      }
    });

  // Review captures use the exact same fixture in an isolated checkout of the requested base.
  if (capture && baseRoot)
    test("capture the requested base at 28px with the same public fixture", async () => {
      const { createServer } = await import("vite");
      const baseVite = await createServer({
        root: baseRoot,
        configFile: path.join(baseRoot, "vite.config.gallery-dev.ts"),
        server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
        logLevel: "error",
      });
      await baseVite.listen();
      try {
        const port = (baseVite.httpServer!.address() as { port: number }).port;
        for (const { engine, browser } of browsers)
          for (const theme of ["light", "dark"]) {
            const page = await browser.newPage({ viewport: { width: 760, height: 1100 } });
            try {
              await page.goto(
                `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "reading", theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors" })}`,
              );
              await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
              await page.locator(".cv-edit-diff__body [data-line]").first().waitFor({ state: "attached" });
              await page.locator(".cv-diagram").scrollIntoViewIfNeeded();
              await page.locator(".cv-diagram__error").waitFor();
              await page.evaluate(async () => {
                const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
                const { setChatDisplay } = await import(modulePath);
                setChatDisplay({ "agentPane.display.font.size": 28 });
              });
              for (const [width, zoom] of [
                [760, 1],
                [390, 1.25],
              ] as const) {
                await page.setViewportSize({ width, height: 1100 });
                await page.evaluate((zoom) => {
                  document.documentElement.style.zoom = String(zoom);
                  document.querySelector("main.acpmux-scroll")!.scrollTop = 0;
                }, zoom);
                await page.screenshot({ path: path.join(capture, `base-${engine}-${theme}-28-${width}.png`) });
              }
            } finally {
              await page.close();
            }
          }
      } finally {
        await baseVite.close();
      }
    });
});
