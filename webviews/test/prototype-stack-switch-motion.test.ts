// Workspace switches keep the sidebar list in place. The prototype used to key and animate the
// list root, which made every space change flash and briefly slide the rows into a new layout.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("prototype-stack-switch-motion.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("prototype-stack-switch-motion: skipping (run `bunx playwright install chromium`)");
    describe.skip("prototype stack switch motion", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/prototype.html");
    browser = await chromium.launch({ headless: true });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("switching spaces reuses the list without starting list motion", async () => {
    const page: Page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await page.addInitScript(() => {
      const motionStarts: string[] = [];
      (window as unknown as { prototypeMotionStarts: string[] }).prototypeMotionStarts = motionStarts;
      document.addEventListener(
        "animationstart",
        (event) => {
          if ((event.target as Element).matches?.(".proto-stack-list")) motionStarts.push("animation");
        },
        true,
      );
      document.addEventListener(
        "transitionrun",
        (event) => {
          if ((event.target as Element).matches?.(".proto-stack-list")) motionStarts.push("transition");
        },
        true,
      );
    });
    try {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}/prototype.html`);
      await page.locator(".proto-stack-list").waitFor();
      await page.evaluate(() => {
        (window as unknown as { prototypeList: Element }).prototypeList = document.querySelector(".proto-stack-list")!;
      });

      await page.getByRole("tab", { name: "Atlas" }).click();
      await page.waitForFunction(() => document.querySelector(".proto-stack-label span")?.textContent === "Atlas");

      const state = await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".proto-stack-list")!;
        const style = getComputedStyle(list);
        return {
          sameNode: (window as unknown as { prototypeList: Element }).prototypeList === list,
          animationName: style.animationName,
          transform: style.transform,
          opacity: style.opacity,
          motionStarts: (window as unknown as { prototypeMotionStarts: string[] }).prototypeMotionStarts,
        };
      });
      expect(state).toEqual({
        sameNode: true,
        animationName: "none",
        transform: "none",
        opacity: "1",
        motionStarts: [],
      });
    } finally {
      await page.close();
    }
  });
});
