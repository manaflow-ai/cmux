// Exercise the real Needs You gallery and its stylesheet cascade.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("needs-you-hover.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.needs-you", { browser, params: { variant: "list" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const styles = (element: Locator) =>
    element.evaluate((node) => {
      const style = getComputedStyle(node);
      return { background: style.backgroundColor, color: style.color };
    });

  for (const theme of ["Apple System Colors Light", "Apple System Colors"]) {
    test(`${theme}: only the hovered Needs You control highlights`, async () => {
      const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
      try {
        const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
        await page.goto(`${base}${galleryFrame("agent-pane.needs-you", { variant: "list", theme })}`);
        const row = page.locator(".acpmux-needs-you-item").first();
        const askAbout = row.locator(".acpmux-needs-you-ask-about");
        await askAbout.waitFor();
        await page.mouse.move(0, 0);
        const rowRest = await styles(row);
        const askRest = await styles(askAbout);

        await row.locator(".acpmux-needs-you-ask").hover();
        expect(await styles(row)).toEqual(rowRest);
        expect(await styles(askAbout)).toEqual(askRest);

        await askAbout.hover();
        expect(await styles(row)).toEqual(rowRest);
        expect((await styles(askAbout)).background).not.toBe(askRest.background);
        expect((await styles(askAbout)).color).not.toBe(askRest.color);

        await page.mouse.move(0, 0);
        expect(await styles(row)).toEqual(rowRest);
        expect(await styles(askAbout)).toEqual(askRest);
      } finally {
        await page.close();
      }
    });
  }
});
