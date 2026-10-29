// The New Tab project trigger keeps its label and chevron together at narrow widths.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-project-chip-fit.test.ts", async () => {
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
    await warmGalleryFrame(vite, "agent-pane.new-tab", {
      browser,
      params: { variant: "inherited-project", theme: "Apple System Colors" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["Apple System Colors Light", "Apple System Colors"])
    for (const width of [260, 360, 720])
      test(`${theme} ${width}px: project label and chevron remain adjacent`, async () => {
        const page = await browser!.newPage({ viewport: { width, height: 560 } });
        const port = (vite!.httpServer!.address() as { port: number }).port;
        await page.goto(
          `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "inherited-project", theme })}`,
        );
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        const result = await page.locator(".acpmux-project-button").evaluate((button) => {
          const label = button.querySelector<HTMLElement>(":scope > span:not(.acpmux-project-badge)")!;
          const chevron = button.querySelector<HTMLElement>(":scope > .acpmux-icon:last-child")!;
          const buttonRect = button.getBoundingClientRect();
          const labelRect = label.getBoundingClientRect();
          const chevronRect = chevron.getBoundingClientRect();
          return {
            labelText: label.textContent,
            labelRight: labelRect.right,
            chevronLeft: chevronRect.left,
            buttonRight: buttonRect.right,
            gap: chevronRect.left - labelRect.right,
          };
        });
        expect(result.labelText).toContain("atlas-web");
        expect(result.labelRight).toBeLessThanOrEqual(result.chevronLeft + 0.5);
        expect(result.chevronLeft).toBeLessThanOrEqual(result.buttonRight + 0.5);
        expect(result.gap).toBeGreaterThanOrEqual(0);
        expect(result.gap).toBeLessThanOrEqual(8);
        await page.screenshot({
          path: `/tmp/newtab-project-chip-${theme.includes("Light") ? "light" : "dark"}-${width}.png`,
        });
        await page.close();
      });
});
