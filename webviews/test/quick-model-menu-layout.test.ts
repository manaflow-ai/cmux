// Real Chromium exercises the shipped picker through its single gallery fixture.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("quick-model-menu-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "new-tab.quick-model-menu", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(variant: string, width = 640, height = 560) {
    const page = await browser.newPage({ viewport: { width, height } });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame("new-tab.quick-model-menu", { variant, width, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }

  const bounds = async (page: Page, selector: string) => (await page.locator(selector).boundingBox())!;

  test("downward Claude menu ends immediately after Fast even with ten distinct harnesses", async () => {
    const page = await open("claude-many-harnesses");
    try {
      const menu = await bounds(page, ".acpmux-quick-menu");
      const fast = await bounds(page, ".acpmux-quick-fast");
      const chip = await bounds(page, "button[data-menu=model]");
      expect(menu.y).toBeGreaterThan(chip.y);
      expect(menu.y + menu.height - fast.y - fast.height).toBeLessThan(12);
      expect(await page.locator(".acpmux-quick-rail-tab").count()).toBe(10);
      expect(await page.locator(".acpmux-quick-fast").innerText()).toBe("Fast mode");
      expect(await page.locator(".acpmux-quick-list").innerText()).toContain("Claude subscription");
    } finally {
      await page.close();
    }
  });

  test("harness controls keep their position while each direction follows visible content", async () => {
    for (const variant of ["claude-many-harnesses", "combined", "chat-flipped"]) {
      const page = await open(variant);
      try {
        const rail = await bounds(page, ".acpmux-quick-rail");
        const menu = await bounds(page, ".acpmux-quick-menu");
        await page.getByRole("button", { name: "Unii", exact: true }).click();
        await page.waitForFunction(
          (y) => Math.abs(document.querySelector(".acpmux-quick-rail")!.getBoundingClientRect().y - y) < 1,
          rail.y,
        );
        const nextRail = await bounds(page, ".acpmux-quick-rail");
        const nextMenu = await bounds(page, ".acpmux-quick-menu");
        expect(Math.abs(nextRail.y - rail.y)).toBeLessThan(1);
        expect(Math.abs(nextRail.x - rail.x)).toBeLessThan(1);
        expect(nextMenu.width).toBe(menu.width);
        expect(nextMenu.height).toBeLessThan(menu.height);
        expect(await page.locator(".acpmux-quick-list").innerText()).toContain("Signed out");
      } finally {
        await page.close();
      }
    }
  });

  test("a midpoint menu keeps its opening side as tall content becomes short", async () => {
    const page = await open("newtab-midpoint");
    try {
      const menu = page.locator(".acpmux-quick-menu");
      await page.waitForFunction(
        () => document.querySelector(".acpmux-quick-menu")?.getAttribute("data-side") === "top",
      );
      const rail = await bounds(page, ".acpmux-quick-rail");
      await page.getByRole("button", { name: "Unii", exact: true }).click();
      await page.waitForFunction(
        () => document.querySelector(".acpmux-quick-menu")!.getBoundingClientRect().height < 230,
      );
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
      expect(await menu.getAttribute("data-side")).toBe("top");
      expect(Math.abs((await bounds(page, ".acpmux-quick-rail")).y - rail.y)).toBeLessThan(1);
    } finally {
      await page.close();
    }
  });

  test("keyboard-selected harnesses stay visible in an overflowing strip", async () => {
    const page = await open("claude-many-harnesses", 320);
    try {
      await page.keyboard.press("ArrowLeft");
      const selected = page.locator(".acpmux-quick-rail-tab[aria-pressed=true]");
      await page.waitForFunction(
        () =>
          document.querySelector(".acpmux-quick-rail-tab[aria-pressed=true]")?.getAttribute("aria-label") === "Goose",
      );
      const button = (await selected.boundingBox())!;
      const rail = await bounds(page, ".acpmux-quick-rail");
      expect(button.x).toBeGreaterThanOrEqual(rail.x);
      expect(button.x + button.width).toBeLessThanOrEqual(rail.x + rail.width);
    } finally {
      await page.close();
    }
  });

  test("reopening a scrolled menu restores its first-row inset without a top fade", async () => {
    const page = await open("claude-many-harnesses", 320, 290);
    try {
      await page.locator(".acpmux-quick-body").evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await page.waitForFunction(() => document.querySelector(".acpmux-quick-body")?.hasAttribute("data-scrolled"));
      await page.keyboard.press("Escape");
      await page.locator(".acpmux-quick-menu").waitFor({ state: "hidden" });
      await page.locator("button[data-menu=model]").click();
      await page.locator(".acpmux-quick-menu").waitFor();
      expect(await page.locator(".acpmux-quick-body").getAttribute("data-scrolled")).toBeNull();
      expect(await page.locator(".acpmux-quick-body").evaluate((node) => node.scrollTop)).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("launch profiles and route-backed accounts occupy separate submenus", async () => {
    for (const [label, choice, absent] of [
      ["Profile", "Subrouter", "API key"],
      ["Account", "API key", "Subrouter"],
    ]) {
      const page = await open("claude");
      try {
        await page.getByRole("menuitem", { name: new RegExp("^" + label) }).hover();
        await page.getByRole("menuitemradio", { name: choice, exact: true }).waitFor();
        expect(await page.getByRole("menuitemradio", { name: absent, exact: true }).count()).toBe(0);
      } finally {
        await page.close();
      }
    }
  });

  test("Fast switch toggles with the keyboard and stays inside a narrow short window", async () => {
    const page = await open("claude-many-harnesses", 320, 290);
    try {
      const menu = await bounds(page, ".acpmux-quick-menu");
      expect(menu.x).toBeGreaterThanOrEqual(0);
      expect(menu.y).toBeGreaterThanOrEqual(0);
      expect(menu.x + menu.width).toBeLessThanOrEqual(320);
      expect(menu.y + menu.height).toBeLessThanOrEqual(290);
      const body = page.locator(".acpmux-quick-body");
      expect(await body.getAttribute("data-scrolled")).toBeNull();
      const first = (await page.locator(".acpmux-quick-list [role=menuitemradio]").first().boundingBox())!;
      const inset = await bounds(page, ".acpmux-quick-body");
      expect(first.y - inset.y).toBeGreaterThanOrEqual(6);
      await body.evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await page.waitForFunction(() => document.querySelector(".acpmux-quick-body")?.hasAttribute("data-scrolled"));
      const fast = page.getByRole("menuitemcheckbox", { name: "Fast mode", exact: true });
      await fast.focus();
      await page.keyboard.press("Space");
      expect(await fast.getAttribute("aria-checked")).toBe("true");
      await page.keyboard.press("Space");
      expect(await fast.getAttribute("aria-checked")).toBe("false");
      const track = await bounds(page, ".acpmux-quick-fast-toggle");
      expect(track.width).toBeGreaterThan(track.height);
    } finally {
      await page.close();
    }
  });
});
