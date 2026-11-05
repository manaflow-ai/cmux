// cmux-web-test-timeout: 300
// The shipped columns picker must leave room for model names as chrome text grows.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("model-picker-scaling.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  const browsers = new Map<string, Browser>();
  const entry = "agent-pane.model-picker";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browsers.set("chromium", await chromium.launch({ headless: true }));
    browsers.set("webkit", await webkit.launch({ headless: true }));
    await warmGalleryFrame(vite, entry, {
      browser: browsers.get("chromium"),
      params: { variant: "reported-codex-menu" },
    });
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  async function open(engine: string, width = 1200) {
    const page = await browsers.get(engine)!.newPage({ viewport: { width, height: 1000 } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame(entry, { variant: "reported-codex-menu", width, height: 1000 })}`,
    );
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    await page.locator(".acpmux-cols-body").waitFor();
    return page;
  }

  const geometry = (page: Page) =>
    page.evaluate(() => {
      const box = (selector: string) => document.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
      return {
        model: box(".acpmux-cols-body > [role=listbox]").width,
        height: box(".acpmux-cols-frame").height,
        rail: box(".acpmux-cols-rail").width,
      };
    });

  for (const engine of ["chromium", "webkit"]) {
    test(`${engine}: default model names fit beside the star and check`, async () => {
      const page = await open(engine);
      try {
        expect((await geometry(page)).model).toBeGreaterThanOrEqual(230);
        const labels = await page
          .locator(".acpmux-cols-body > [role=listbox] [role=option] .acpmux-cols-name")
          .evaluateAll((nodes) => nodes.map((node) => ({ width: node.clientWidth, content: node.scrollWidth })));
        expect(labels.length).toBeGreaterThan(4);
        expect(labels.every((label) => label.content <= label.width + 1)).toBe(true);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: an open picker grows with interface size and independent chrome text size`, async () => {
      const page = await open(engine);
      try {
        const initial = await geometry(page);
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        await page.waitForFunction(() => document.querySelector(".acpmux-cols")!.getBoundingClientRect().width > 600);
        const scaled = await geometry(page);
        expect(scaled.model).toBeGreaterThan(initial.model * 1.45);
        expect(scaled.rail).toBeGreaterThan(initial.rail * 1.45);
        expect(scaled.height).toBeGreaterThan(initial.height * 1.35);
        await page.evaluate(() => {
          document.documentElement.style.setProperty("--cmux-interface-scale", "1");
          document.documentElement.style.setProperty("--text-body", "20px");
        });
        await page.waitForFunction(
          () => document.querySelector(".acpmux-cols-body > [role=listbox]")!.getBoundingClientRect().width > 350,
        );
        expect((await geometry(page)).model).toBeGreaterThan(initial.model * 1.45);
      } finally {
        await page.close();
      }
    });

    test(`${engine}: a narrow picker keeps readable names inside its columns`, async () => {
      const page = await open(engine, 360);
      try {
        await page.evaluate(() => document.documentElement.style.setProperty("--cmux-interface-scale", "1.5"));
        const layout = await page.locator(".acpmux-cols").evaluate((menu) => {
          const body = menu.querySelector<HTMLElement>(".acpmux-cols-body")!;
          const names = [...menu.querySelectorAll<HTMLElement>("[role=listbox] [role=option] .acpmux-cols-name")];
          return {
            width: menu.getBoundingClientRect().width,
            bodyWidth: body.clientWidth,
            contentWidth: body.scrollWidth,
            names: names.map((name) => ({
              width: name.clientWidth,
              content: name.scrollWidth,
              whiteSpace: getComputedStyle(name).whiteSpace,
            })),
          };
        });
        expect(layout.width).toBeLessThanOrEqual(360);
        expect(layout.contentWidth).toBeLessThanOrEqual(layout.bodyWidth + 1);
        expect(layout.names.length).toBeGreaterThan(4);
        expect(
          layout.names.every(
            (name) => name.width > 0 && name.content <= name.width + 1 && name.whiteSpace === "normal",
          ),
        ).toBe(true);
      } finally {
        await page.close();
      }
    });
  }
});
