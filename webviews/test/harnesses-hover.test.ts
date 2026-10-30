// Exercise the real HarnessesScreen and its full stylesheet cascade in the gallery.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("harnesses-hover.test.ts", async () => {
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
    await warmGalleryFrame(vite, "agent-pane.harnesses", { browser, params: { variant: "hover" } });
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
    for (const accent of [undefined, "blue"]) {
      for (const status of ["ready", "signIn", "notInstalled"]) {
        test(`${theme}, ${accent ?? "neutral"}, ${status}: only the hovered action highlights`, async () => {
          const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
          try {
            const base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
            await page.goto(`${base}${galleryFrame("agent-pane.harnesses", { variant: "hover", theme, accent })}`);
            const row = page.locator(`[data-harness-status="${status}"]`).first();
            const button = row.locator(".acpmux-harness-action");
            await button.waitFor();
            await page.mouse.move(0, 0);
            const rowRest = await styles(row);
            const buttonRest = await styles(button);
            if (status !== "ready") {
              // Resolve the actual theme tokens to colors, independent of the action's rules.
              const primary = await button.evaluate((node) => {
                const probe = document.createElement("span");
                probe.style.background = "var(--agent-accent)";
                probe.style.color = "var(--agent-accent-text, #fff)";
                node.append(probe);
                const style = getComputedStyle(probe);
                const result = { background: style.backgroundColor, color: style.color };
                probe.remove();
                return result;
              });
              expect(buttonRest).toEqual(primary);
            }
            // The flexible text area is inside the row, outside its sole action target.
            await row.locator(".acpmux-harness-text").hover();
            expect(await styles(row)).toEqual(rowRest);
            expect(await styles(button)).toEqual(buttonRest);
            await button.hover();
            expect(await styles(row)).toEqual(rowRest);
            expect((await styles(button)).background).not.toBe(buttonRest.background);
            expect((await styles(button)).color).toBe(buttonRest.color);
            await page.mouse.move(0, 0);
            expect(await styles(button)).toEqual(buttonRest);
            expect(await styles(row)).toEqual(rowRest);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
});
