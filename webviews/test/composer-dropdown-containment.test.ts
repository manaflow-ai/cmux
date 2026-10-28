import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Locator, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-dropdown-containment.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let server: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    server = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0, strictPort: false },
      logLevel: "error",
    });
    await server.listen();
    browser = await chromium.launch();
    await warmGalleryFrame(server, "agent-pane.composer-context", { browser, params: { variant: "folder-menu" } });
    await warmGalleryFrame(server, "agent-pane.project-chooser", { browser, params: { variant: "downward-3" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  async function open(entry: string, variant: string, height: number) {
    const page = await browser.newPage({ viewport: { width: 760, height } });
    const port = (server.httpServer!.address() as { port: number }).port;
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width: 760, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    expect(await page.locator("html").getAttribute("data-gallery-variant")).toBe(variant);
    return page;
  }

  async function contained(page: Page, popup: Locator) {
    const bounds = await popup.boundingBox();
    expect(bounds).not.toBeNull();
    expect(bounds!.y).toBeGreaterThanOrEqual(0);
    expect(bounds!.y + bounds!.height).toBeLessThanOrEqual(page.viewportSize()!.height + 1);
  }

  async function viewportContained(popup: Locator, viewport: Locator) {
    const outer = (await popup.boundingBox())!;
    const area = (await viewport.boundingBox())!;
    expect(area.y).toBeGreaterThanOrEqual(outer.y - 1);
    expect(area.y + area.height).toBeLessThanOrEqual(outer.y + outer.height + 2);
  }

  async function reachable(row: Locator, viewport: Locator, popup: Locator, checkViewport = true) {
    if (checkViewport) await viewportContained(popup, viewport);
    await row.scrollIntoViewIfNeeded();
    const item = (await row.boundingBox())!;
    const area = (await viewport.boundingBox())!;
    const outer = (await popup.boundingBox())!;
    if (checkViewport) {
      expect(item.y).toBeGreaterThanOrEqual(area.y - 1);
      expect(item.y + item.height).toBeLessThanOrEqual(area.y + area.height + 1);
    }
    expect(item.y).toBeGreaterThanOrEqual(outer.y - 1);
    expect(item.y + item.height).toBeLessThanOrEqual(outer.y + outer.height + 1);
  }

  for (const height of [180, 560]) {
    test(`folder menu opens inside a ${height}px window and its last project is reachable`, async () => {
      const page = await open("agent-pane.composer-context", "folder-menu", height);
      try {
        const popup = page.locator(".acpmux-folder-popover");
        await contained(page, popup);
        const trigger = page.getByRole("button", { name: "Folder", exact: true });
        const triggerBounds = (await trigger.boundingBox())!;
        const popupBounds = (await popup.boundingBox())!;
        if (height >= 560) {
          expect(popupBounds.y).toBeGreaterThanOrEqual(triggerBounds.y + triggerBounds.height - 1);
        }
        const projects = popup.locator('[role="option"]:has(.acpmux-location-row)');
        expect(await projects.count()).toBe(3);
        
        await contained(page, popup);
        expect(await page.getByRole("button", { name: "Folder", exact: true }).getAttribute("aria-expanded")).toBe("true");
      } finally {
        await page.close();
      }
    });

    test(`environment menu retains gpu-box inside a ${height}px window`, async () => {
      const page = await open("agent-pane.composer-context", "environment-picker", height);
      try {
        const popup = page.locator(".acpmux-env-popover");
        await contained(page, popup);
        const trigger = page.getByRole("button", { name: /^Environment/ });
        const triggerBounds = (await trigger.boundingBox())!;
        const popupBounds = (await popup.boundingBox())!;
        if (height >= 560) {
          expect(popupBounds.y).toBeGreaterThanOrEqual(triggerBounds.y + triggerBounds.height - 1);
        }
        const gpu = popup.locator('[role="option"]').filter({ hasText: "gpu-box" });
        expect(await gpu.count()).toBe(1);
        expect(await gpu.locator('[data-connected="true"]').count()).toBe(1);
        expect(await gpu.locator("kbd").innerText()).toBe("⌥⌘2");
        
        await contained(page, popup);
      } finally {
        await page.close();
      }
    });
  }

  for (const [variant, triggerName, popupSelector, height, top] of [
    ["environment-picker", /^Environment/, ".acpmux-env-popover", 760, "740px"],
  ] as const) {
    test(`${variant} flips above when the trigger is at the bottom edge`, async () => {
      const page = await open("agent-pane.composer-context", variant, height);
      try {
        await page.keyboard.press("Escape");
        const context = page.locator(".acpmux-composer-context");
        await context.evaluate((node) => {
          const element = node as HTMLElement;
          element.style.position = "fixed";
          element.style.left = "8px";
          element.style.top = top;
          element.style.bottom = "auto";
        });
        const trigger = typeof triggerName === "string"
          ? page.getByRole("button", { name: triggerName, exact: true })
          : page.getByRole("button", { name: triggerName });
        await trigger.locator("..").evaluate((node) => {
          const rect = node.getBoundingClientRect();
          Object.defineProperty(node, "getBoundingClientRect", {
            configurable: true,
            value: () => new DOMRect(rect.x, 700, rect.width, rect.height),
          });
        });
        await trigger.dispatchEvent("pointerdown", { button: 0 });
        await trigger.dispatchEvent("click", { detail: 1 });
        const popup = page.locator(popupSelector);
        await popup.waitFor();
        expect(await popup.getAttribute("data-side")).toBe("top");
        await contained(page, popup);
      } finally {
        await page.close();
      }
    });
  }

  for (const count of [3, 8, 15]) {
    test(`project gallery renders all ${count} projects with contained scrolling`, async () => {
      const page = await open("agent-pane.project-chooser", `downward-${count}`, 300);
      try {
        const popup = page.locator(".acpmux-project-menu");
        await contained(page, popup);
        expect(await popup.locator("[data-path]").count()).toBe(count);
        const actions = popup.locator(".ui-combobox-pinned");
        const before = await actions.boundingBox();
        const last = popup.locator('[role="option"]').filter({ has: page.locator(`[data-path$="/project-${count}"]`) });
        await reachable(last, popup.locator(".ui-combobox-viewport"), popup, false);
        expect(await actions.boundingBox()).toEqual(before);
        await contained(page, popup);
      } finally {
        await page.close();
      }
    });
  }
});
