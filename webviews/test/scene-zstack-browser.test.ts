// An app scene ZStack lays every layer in its one cell, as the native ZStack does, also the children
// of a Group or ForEach (display: contents): a keyed card swap draws the entering card over the
// leaving one, centered, and a Particles field fills the whole stack. Before, those children took new
// grid rows: the entering card stacked under the leaving one and the field sat in an empty first row,
// so every burst drew on the stack's top edge. Real Chromium on scene.css (browser/scene-zstack.html).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("scene-zstack-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser | undefined;
  let page: Page;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/scene-zstack.html");
    browser = await chromium.launch({ headless: true });
    page = await browser.newPage({ viewport: { width: 800, height: 600 } });
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}/test/browser/scene-zstack.html`);
    await page.waitForFunction(() => document.documentElement.dataset.harnessReady === "true");
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const box = async (id: string) => (await page.getByTestId(id).boundingBox())!;

  describe("app scene ZStack", () => {
    test("a ForEach's leaving and entering cards share the one cell, centered", async () => {
      const stack = await box("stack");
      const leaving = await box("leaving");
      const entering = await box("entering");
      expect(entering.y).toBe(leaving.y);
      expect(entering.x).toBe(leaving.x);
      expect(entering.x - stack.x).toBe((stack.width - entering.width) / 2);
      expect(entering.y - stack.y).toBe((stack.height - entering.height) / 2);
    });

    test("a Particles field fills the whole stack", async () => {
      const stack = await box("stack");
      const field = await box("field");
      expect(field).toEqual(stack);
    });
  });
});
