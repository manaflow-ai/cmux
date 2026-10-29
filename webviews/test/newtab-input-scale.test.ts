// New Tab's shell glyph and placeholder share relative vertical spacing as content text scales.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("newtab-input-scale.test.ts", async () => {
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
      params: { variant: "minimal-default", theme: "Apple System Colors" },
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const theme of ["Apple System Colors Light", "Apple System Colors"])
    test(`${theme}: input padding and glyph use the content scale`, async () => {
      const page = await browser!.newPage({ viewport: { width: 720, height: 560 } });
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.new-tab", { variant: "minimal-default", theme })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const result = await page.locator(".nt-input").evaluate((row) => {
        const input = row.querySelector<HTMLElement>(".nt-field")!;
        const glyph = row.querySelector<HTMLElement>(".nt-input-glyph");
        const style = getComputedStyle(row);
        const field = getComputedStyle(input);
        const glyphStyle = glyph ? getComputedStyle(glyph) : undefined;
        return {
          pad: style.getPropertyValue("--nt-input-pad-block"),
          fieldPad: field.paddingTop,
          glyphTop: glyphStyle?.top,
        };
      });
      expect(result.pad).toBe("1em");
      expect(result.fieldPad).toBe(result.glyphTop ?? "");
      await page.screenshot({ path: `/tmp/newtab-input-scale-${theme.includes("Light") ? "light" : "dark"}.png` });
      await page.close();
    });
});
