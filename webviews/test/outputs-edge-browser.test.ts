// The actual Outputs list owns the scroll: only an edge with hidden rows receives a band.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("outputs-edge-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const entry = "agent-pane.outputs-edge";
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser });
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  async function open(variant = "subtle") {
    const page = await browser.newPage({ viewport: { width: 420, height: 440 }, deviceScaleFactor: 2 });
    await page.goto(base + galleryFrame(entry, { variant, width: 420, height: 440 }));
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }
  const edges = (page: Page) =>
    page.evaluate(() => {
      const list = document.querySelector<HTMLElement>('ul[data-section="outputs"]')!;
      const wrap = list.parentElement!;
      return {
        top: getComputedStyle(wrap, "::before").opacity,
        bottom: getComputedStyle(wrap, "::after").opacity,
        pointer: getComputedStyle(wrap, "::after").pointerEvents,
        blur: getComputedStyle(wrap, "::after").backdropFilter,
        height: getComputedStyle(wrap, "::after").height,
        overflow: list.scrollHeight > list.clientHeight,
      };
    });
  async function scroll(page: Page, where: "middle" | "bottom" | "top") {
    await page.locator('ul[data-section="outputs"]').evaluate((list, target) => {
      list.scrollTop = target === "top" ? 0 : target === "bottom" ? list.scrollHeight : 120;
    }, where);
    await page.waitForFunction((target) => {
      const list = document.querySelector('ul[data-section="outputs"]')!;
      return (
        list.hasAttribute("data-fade-top") === (target !== "top") &&
        list.hasAttribute("data-fade-bottom") === (target !== "bottom")
      );
    }, where);
  }
  test("top, middle and bottom reflect hidden rows, and folding removes both bands", async () => {
    const page = await open();
    try {
      expect((await edges(page)).overflow).toBe(false);
      expect((await edges(page)).top).toBe("0");
      expect((await edges(page)).bottom).toBe("0");
      await page.getByRole("button", { name: "Show more", exact: true }).click();
      await page.waitForFunction(() =>
        document.querySelector('ul[data-section="outputs"]')?.hasAttribute("data-fade-bottom"),
      );
      expect((await edges(page)).top).toBe("0");
      expect((await edges(page)).bottom).toBe("1");
      await scroll(page, "middle");
      expect((await edges(page)).top).toBe("1");
      expect((await edges(page)).bottom).toBe("1");
      await scroll(page, "bottom");
      expect((await edges(page)).top).toBe("1");
      expect((await edges(page)).bottom).toBe("0");
      await page.getByRole("button", { name: "Show less", exact: true }).click();
      await page.waitForFunction(
        () => !document.querySelector('ul[data-section="outputs"]')?.hasAttribute("data-fade-bottom"),
      );
      expect((await edges(page)).top).toBe("0");
      expect((await edges(page)).bottom).toBe("0");
      await page.getByRole("button", { name: "Outputs", exact: true }).click();
      expect(await page.locator('ul[data-section="outputs"]').isVisible()).toBe(false);
    } finally {
      await page.close();
    }
  });
  test("decorative bands pass clicks to file rows and honor reduced transparency", async () => {
    const page = await open();
    try {
      await page.getByRole("button", { name: "Show more", exact: true }).click();
      await scroll(page, "middle");
      expect((await edges(page)).pointer).toBe("none");
      expect((await edges(page)).blur).toBe("blur(5px)");
      const point = await page.locator('ul[data-section="outputs"]').evaluate((list) => {
        const box = list.getBoundingClientRect();
        const x = box.left + 35,
          y = box.top + 4;
        const button = document.elementFromPoint(x, y)?.closest("button");
        return { x, y, text: button?.textContent ?? "" };
      });
      expect(point.text).toContain("output-");
      await page.mouse.click(point.x, point.y);
      expect(await page.locator("output[data-opened-file]").textContent()).toContain("/demo/src/output-");
      await page.evaluate(() => document.documentElement.setAttribute("data-reduce-transparency", ""));
      expect((await edges(page)).blur).toBe("none");
      expect((await edges(page)).top).toBe("0");
      expect((await edges(page)).bottom).toBe("0");
      await page.evaluate(() => document.documentElement.removeAttribute("data-reduce-transparency"));
      const media = await page.context().newCDPSession(page);
      await media.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-reduced-transparency", value: "reduce" }],
      });
      expect((await edges(page)).top).toBe("0");
      expect((await edges(page)).bottom).toBe("0");
      await media.send("Emulation.setEmulatedMedia", { features: [] });
      await media.detach();
      await page.emulateMedia({ reducedMotion: "reduce" });
      expect((await edges(page)).top).toBe("1");
      expect((await edges(page)).bottom).toBe("1");
    } finally {
      await page.close();
    }
  });
  for (const [variant, height] of [
    ["subtle", "12px"],
    ["balanced", "16px"],
    ["roomy", "24px"],
  ]) {
    test(`${variant}: the gallery renders its scoped band size`, async () => {
      const page = await open(variant);
      try {
        expect((await edges(page)).height).toBe(height);
      } finally {
        await page.close();
      }
    });
  }
});
