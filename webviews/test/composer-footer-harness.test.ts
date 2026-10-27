// Leo, 2026-10-24: the quiet row must not repeat the harness. Harness choice belongs in the model
// picker rail, which is the only place this test exercises for switching.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-footer-harness.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-footer-harness: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer footer harness", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (variant: string, entry = "agent-pane.composer") =>
    `http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${galleryFrame(entry, { variant })}`;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.composer", "agent-pane.new-tab"], { browser });
  });

  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(
    variant: string,
    width: number,
    { entry, settled = ".acpmux-composer-foot .acpmux-access" }: { entry?: string; settled?: string } = {},
  ): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height: 560 } });
    await page.goto(url(variant, entry));
    const ready = () =>
      page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 30_000,
      });
    await ready().catch(async () => {
      await page.reload();
      await ready();
    });
    await page.waitForSelector(settled);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  }

  async function row(page: Page) {
    return page.$eval(".acpmux-composer-foot", (foot) => {
      const items = (container: Element): HTMLElement[] =>
        [...container.children].flatMap((child) => {
          if (!(child instanceof HTMLElement)) return [];
          if (getComputedStyle(child).display === "contents") return items(child);
          const rect = child.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 && getComputedStyle(child).display !== "none" ? [child] : [];
        });
      return items(foot)
        .map((item) => ({
          className: item.className,
          left: item.getBoundingClientRect().left,
          right: item.getBoundingClientRect().right,
        }))
        .sort((a, b) => a.left - b.left);
    });
  }

  for (const variant of ["footer-harness", "footer-harness-codex"] as const) {
    test(`${variant}: the quiet row has no harness label`, async () => {
      const page = await open(variant, 760);
      const foot = await page.$eval(".acpmux-composer-foot", (element) => ({
        harnesses: element.querySelectorAll(".acpmux-foot-harness").length,
        access: element.querySelectorAll(".acpmux-access").length,
        model: element.querySelectorAll(".acpmux-model").length,
      }));
      expect(foot).toEqual({ harnesses: 0, access: 1, model: 1 });
      await page.close();
    });
  }

  test("a new chat opens the harness-only rail from the model picker", async () => {
    const page = await open("footer-harness-new-chat", 760);
    await page.keyboard.press("Escape");
    await page.waitForSelector(".acpmux-quick-menu", { state: "detached", timeout: 5_000 });
    expect(await page.locator(".acpmux-composer-foot .acpmux-foot-harness").count()).toBe(0);
    await page.click(".acpmux-composer-foot .acpmux-model .acpmux-picker-button");
    await page.waitForSelector(".acpmux-quick-menu", { timeout: 5_000 });
    const rail = await page.$$eval(".acpmux-quick-menu .acpmux-quick-rail-tab[aria-label]", (tabs) =>
      tabs.map((tab) => tab.getAttribute("aria-label")),
    );
    expect(rail).toContain("Claude Code");
    expect(rail).toContain("Codex");
    await page.close();
  });

  test("with no harness installed the row still says Add harness", async () => {
    const page = await open("no-harness-installed", 760, {
      entry: "agent-pane.new-tab",
      settled: ".acpmux-composer-foot .acpmux-add-harness",
    });
    const foot = await page.$eval(".acpmux-composer-foot", (element) => ({
      harness: element.querySelectorAll(".acpmux-foot-harness").length,
      modes: element.querySelectorAll(".acpmux-mode, .acpmux-access").length,
      text: element.textContent?.trim(),
    }));
    expect(foot).toEqual({ harness: 0, modes: 0, text: "Add harness" });
    await page.close();
  });

  test("a model switch does not add a harness item to the quiet row", async () => {
    const page = await open("model-switching", 760);
    expect(await page.locator(".acpmux-composer-foot .acpmux-foot-harness").count()).toBe(0);
    expect(await page.locator(".acpmux-composer-foot .acpmux-model").count()).toBe(1);
    await page.close();
  });

  for (const variant of ["footer-harness", "footer-harness-codex"] as const) {
    test(`${variant}: the compact row keeps its controls ordered and inside the footer`, async () => {
      const page = await open(variant, 410);
      const items = await row(page);
      const units = items.map((item) =>
        ["acpmux-access", "acpmux-model", "acpmux-context"].find((name) => item.className.split(" ").includes(name)),
      );
      expect(units).toEqual(["acpmux-access", "acpmux-model", "acpmux-context"]);
      for (let index = 1; index < items.length; index++)
        expect(items[index]!.left).toBeGreaterThanOrEqual(items[index - 1]!.right - 0.5);
      await page.close();
    });
  }
});
