import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "../support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import path from "node:path";

await requireBrowserLane("trailing-plates-diff.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const root = path.resolve(import.meta.dir, "../..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "agent-pane.diff-panel", { timeoutMs: 120_000 });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  for (const mode of ["light", "dark"] as const) {
    test(`${mode}: changes trailing controls have no resting plate`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 860, height: 620 }, reducedMotion: "reduce" });
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.diff-panel", { variant: "last-turn", colorScheme: mode })}`,
      );
      const tools = page.locator(".acpmux-diff-tools").first();
      await tools.waitFor();
      const resting = await tools.evaluate((node) => {
        const style = getComputedStyle(node);
        return { background: style.backgroundColor, boxShadow: style.boxShadow };
      });
      const dir = process.env.ORCH_PLATES_CAPTURE_DIR;
      if (dir) await page.screenshot({ path: `${dir}/changes-${mode}.png` });
      expect(resting).toEqual({ background: "rgba(0, 0, 0, 0)", boxShadow: "none" });
      const button = tools.locator(".acpmux-diff-tool").first();
      await button.hover();
      expect(await button.evaluate((node) => getComputedStyle(node).backgroundColor)).not.toBe("rgba(0, 0, 0, 0)");
      await page.close();
    });
  }
});
