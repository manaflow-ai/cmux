// Collapsed tool-group rows use one inset and an inline chevron across summaries, failure counts,
// group kinds and nested placement (Leo: "this space between command and chevron often gets
// misalinged it seems like there's sometimes an indent?"). The gallery matrix is the fixture and
// this test measures the rendered geometry in Chromium.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-tool-group-alignment.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-tool-group-alignment: skipping (run `bunx playwright install chromium`)");
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
    await warmGalleryFrame(vite, "agent-pane.tool-group-alignment", {
      browser,
      params: { variant: "dark" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("all collapsed group variants keep the caret beside their label", async () => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1200, height: 700 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.tool-group-alignment", { variant: "dark" })}`);
    await page.locator("[data-tool-group-alignment]").waitFor();
    const metrics = await page
      .locator("[data-tool-group-alignment] .tool-group-align-gallery__cell")
      .evaluateAll((cells) =>
        cells.map((cell) => {
          const button = cell.querySelector<HTMLElement>("button.cv-tool")!;
          const icon = cell.querySelector<HTMLElement>(".cv-tool__icon")!;
          const text = cell.querySelector<HTMLElement>(".cv-tool__text")!;
          const chevron = cell.querySelector<SVGElement>(".cv-tool__chevron")!;
          const b = button.getBoundingClientRect();
          const i = icon.getBoundingClientRect();
          const t = text.getBoundingClientRect();
          const c = chevron.getBoundingClientRect();
          return {
            group: cell.getAttribute("data-group"),
            iconInset: i.left - b.left,
            textInset: t.left - b.left,
            caretGap: c.left - t.right,
            gapToken: Number.parseFloat(getComputedStyle(button).getPropertyValue("--cv-disclosure-gap")),
          };
        }),
      );
    const spread = (key: "iconInset" | "textInset") => {
      const values = metrics.map((metric) => metric[key]);
      return Math.max(...values) - Math.min(...values);
    };
    expect(metrics).toHaveLength(6);
    expect(spread("iconInset")).toBeLessThanOrEqual(0.5);
    expect(spread("textInset")).toBeLessThanOrEqual(0.5);
    expect(metrics.every((metric) => metric.caretGap >= -0.5 && metric.caretGap <= metric.gapToken + 0.5)).toBe(true);
    await page.close();
  });
});
