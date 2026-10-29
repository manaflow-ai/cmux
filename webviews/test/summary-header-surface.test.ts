// l10n-allow-file: browser fixture counts and selectors, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("summary-header-surface.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, "agent-pane.summary-card", { browser, params: { variant: "shared-tab-row" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });
  for (const height of [28, 40]) {
    for (const theme of ["Apple System Colors", "Apple System Colors Light"]) {
      test(`inline Summary leaves the ${height}px native tools row clear (${theme})`, async () => {
        const page = await browser.newPage({ viewport: { width: 720, height: 560 } });
        try {
          const port = (server.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "shared-tab-row", theme })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-shell").evaluate((node, pixels) => {
            (node as HTMLElement).style.setProperty("--acpmux-tab-row-height", `${pixels}px`);
          }, height);
          if (process.env.CMUX_SUMMARY_CAPTURE_DIR) {
            await mkdir(process.env.CMUX_SUMMARY_CAPTURE_DIR, { recursive: true });
            await page.screenshot({
              path: path.join(
                process.env.CMUX_SUMMARY_CAPTURE_DIR,
                `summary-${height}-${theme.endsWith("Light") ? "light" : "dark"}.png`,
              ),
            });
          }
          const actual = await page.evaluate(() => {
            const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
            const panel = document.querySelector<HTMLElement>(".acpmux-summary-card")!;
            const head = panel.querySelector<HTMLElement>(".acpmux-summary-card__head")!;
            const counts = panel.querySelector<HTMLElement>(".acpmux-summary-card__counts")!;
            const rect = panel.getBoundingClientRect();
            const header = head.getBoundingClientRect();
            const text = counts.getBoundingClientRect();
            const style = getComputedStyle(counts);
            const tab = document.querySelector(".acpmux-header[data-tab-row]")!.getBoundingClientRect();
            return {
              top: rect.top - shell.getBoundingClientRect().top,
              intersectsTabRow:
                rect.left < tab.right && rect.right > tab.left && rect.top < tab.bottom && rect.bottom > tab.top,
              toolsRight: document.querySelector(".acpmux-header-tools")!.getBoundingClientRect().right,
              shellRight: shell.getBoundingClientRect().right,
              bottom: rect.bottom - shell.getBoundingClientRect().bottom,
              text: counts.textContent,
              countsInside: text.left >= header.left && text.right <= header.right,
              overflow: style.overflowX,
              truncated: counts.scrollWidth > counts.clientWidth,
              ellipsis: style.textOverflow,
              background: style.backgroundColor,
              backdrop: style.backdropFilter,
              mask: style.maskImage,
              before: getComputedStyle(counts, "::before").content,
              after: getComputedStyle(counts, "::after").content,
            };
          });
          expect(actual.text).toContain("2 commands · 1 failed");
          expect(actual.top).toBeGreaterThanOrEqual(height);
          expect(actual.intersectsTabRow).toBe(false);
          expect(actual.bottom).toBeLessThanOrEqual(0);
          expect(actual.toolsRight).toBe(actual.shellRight);
          expect(actual.countsInside).toBe(true);
          expect(actual.truncated).toBe(true);
          expect(actual).toMatchObject({
            overflow: "hidden",
            ellipsis: "ellipsis",
            background: "rgba(0, 0, 0, 0)",
            backdrop: "none",
            mask: "none",
            before: "none",
            after: "none",
          });
        } finally {
          await page.close();
        }
      });
    }
  }
  for (const width of [640, 1000]) {
    for (const height of [28, 40]) {
      test(`Preview leaves the ${height}px native row clear at ${width}px`, async () => {
        const page = await browser.newPage({ viewport: { width, height: 560 }, reducedMotion: "reduce" });
        try {
          const port = (server.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.summary-card", { variant: "preview-tab-row" })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.locator(".acpmux-shell").evaluate((node, pixels) => {
            (node as HTMLElement).style.setProperty("--acpmux-tab-row-height", `${pixels}px`);
          }, height);
          await page.locator(".acpmux-artifact").waitFor();
          const actual = await page.evaluate(() => {
            const shell = document.querySelector(".acpmux-shell")!.getBoundingClientRect();
            const panel = document.querySelector(".acpmux-artifact")!.getBoundingClientRect();
            return { top: panel.top - shell.top, bottom: panel.bottom - shell.bottom };
          });
          expect(actual.top).toBe(height);
          expect(actual.bottom).toBeLessThanOrEqual(0);
        } finally {
          await page.close();
        }
      });
    }
  }
});
