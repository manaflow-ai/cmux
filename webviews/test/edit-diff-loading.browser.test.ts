import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("edit-diff-loading.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    server = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      plugins: [devHighlightWorker()],
      logLevel: "error",
    });
    await server.listen();
    base = `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, "agent-pane.inline-diff-loading", { browser, params: { variant: "loaded" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });
  test.each(["light", "dark"])(
    "%s: placeholders remain visible without borders and match the short loaded body",
    async (scheme) => {
      const page = await browser.newPage({ viewport: { width: 320, height: 260 } });
      const url = (variant: string) =>
        `${base}${galleryFrame("agent-pane.inline-diff-loading", {
          variant,
          theme: "Apple System Colors",
          colorScheme: scheme,
          width: 320,
          height: 260,
        })}`;
      try {
        await page.goto(url("short"));
        await page.locator(".cv-edit-diff__loading-lines").waitFor();
        const pending = await page.evaluate(() => {
          document.documentElement.dataset.borders = "none";
          const lines = document.querySelector<HTMLElement>(".cv-edit-diff__loading-lines")!;
          const style = getComputedStyle(lines);
          const stripe = getComputedStyle(lines, "::before");
          const body = document.querySelector(".cv-edit-diff__body")!;
          return {
            height: body.getBoundingClientRect().height,
            x: lines.getBoundingClientRect().left + parseFloat(style.paddingLeft) + parseFloat(stripe.marginLeft),
            paint: stripe.backgroundImage,
          };
        });
        expect(pending.height).toBeGreaterThan(0);
        expect(pending.paint).toMatch(/(?:rgba\([^)]*, 0\.[1-9]\d*\)|color\([^)]*\/ 0\.[1-9]\d*\))/);
        await page.goto(url("loaded"));
        await page.locator("diffs-container [data-line]").first().waitFor();
        const loaded = await page.evaluate(() => {
          const line = document
            .querySelector("diffs-container")!
            .shadowRoot!.querySelector<HTMLElement>("[data-line]")!;
          return {
            height: document.querySelector(".cv-edit-diff__body")!.getBoundingClientRect().height,
            x: line.getBoundingClientRect().left + parseFloat(getComputedStyle(line).paddingLeft),
          };
        });
        console.log({ scheme, pending, loaded });
        expect(Math.abs(pending.height - loaded.height)).toBeLessThan(1);
        expect(Math.abs(pending.x - loaded.x)).toBeLessThan(1);
      } finally {
        await page.close();
      }
    },
  );
});
