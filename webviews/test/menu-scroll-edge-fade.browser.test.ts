// cmux-web-test-timeout: 600
// aiforui.dev, Using AI at work: overflowing menu rows fade at their scroll edge.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("menu-scroll-edge-fade.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["ui.secondary-list-overflow", "checks", ".acpmux-pr-status", 420, 1000],
    ["ui.secondary-list-overflow", "rules", ".acpmux-rules-list", 420, 1000],
    ["ui.secondary-list-overflow", "people", ".lg-picker-rows", 420, 1000],
    ["ui.menu", "overflowing", ".menu-gallery-popup", 320, 640],
    ["ui.select", "overflowing", ".ui-select-popup", 320, 640],
    ["pages.icon-picker", "categories", ".icon-category-menu", 320, 640],
    ["agent-pane.project-chooser", "long-no-actions", ".ui-combobox-list", 320, 640],
    ["agent-pane.composer-context", "folder-long-list", ".ui-combobox-viewport", 320, 640],
    ["agent-pane.composer-context", "folder-long-list", ".ui-combobox-pinned", 240, 640],
    ["agent-pane.composer-context", "environment-picker-fleet", ".acpmux-env-popover .ui-combobox-list", 320, 640],
    ["agent-pane.add-project-panel", "long-directory", ".acpmux-add-project-list", 320, 640],
    ["new-tab.quick-model-menu", "short-more-models", ".acpmux-quick-body", 320, 640],
    ["agent-pane.slash-menu", "overflowing", ".acpmux-slash-menu", 320, 640],
    ["agent-pane.composer", "slash-menu-full", ".acpmux-slash-menu", 320, 640],
    ["agent-pane.new-tab-page", "omnibar-overflow", ".acpmux-omni", 320, 640],
    ["agent-pane.file-picker-loading", "mentions-overflow", ".acpmux-mention-menu", 420, 1000],
    ["agent-pane.new-tab", "suggestions-overflow", ".nt-rows", 320, 1000],
    ["agent-pane.cloud-repository-picker", "overflowing", ".acpmux-cloud-repository-list", 420, 1000],
    ["agent-pane.session-info-list-overflow", "tasks", '[data-section="tasks"]', 420, 1000],
    ["agent-pane.session-info-list-overflow", "servers", '[data-section="servers"]', 420, 1000],
    ["agent-pane.session-info-list-overflow", "subagents", ".acpmux-session-info-subagents__list", 420, 1000],
    ["agent-pane.changes-git-actions", "new-files-overflow", ".acpmux-git-new-files ul", 640, 1000],
    ["pages.home-channels", "emoji", ".hc-emoji-grid", 640, 1000],
    ["settings.accent-picker", "overflowing", ".theme-list", 640, 1000],
    ["viewer-empty.empty-state", "recents-overflow", ".ve-recent-list", 640, 1000],
  ] as const;
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
    for (const [entry, variant] of scenes) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function open(entry: string, variant: string, height: number, width: number): Promise<Page> {
    const page = await browser.newPage({
      viewport: { width, height },
      deviceScaleFactor: 2,
    });
    const { port } = vite.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
    return page;
  }

  for (const [entry, variant, selector, height, width] of scenes) {
    test(`${entry} ${selector}: overflowing rows fade only at edges with more content`, async () => {
      const page = await open(entry, variant, height, width);
      try {
        const list = page.locator(selector).first();
        await list.waitFor();
        expect(await list.evaluate((node) => node.scrollHeight > node.clientHeight)).toBe(true);
        await list.evaluate((node) => {
          node.scrollTop = 0;
        });
        await page.waitForFunction(
          (selector) => {
            const node = document.querySelector(selector);
            return (
              node?.scrollTop === 0 && node.hasAttribute("data-fade-bottom") && !node.hasAttribute("data-fade-top")
            );
          },
          selector,
          { timeout: 5_000 },
        );
        expect(await list.getAttribute("data-fade-top")).toBeNull();
        expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).not.toBe("none");
        await list.evaluate((node) => {
          node.scrollTop = (node.scrollHeight - node.clientHeight) / 2;
        });
        await page.waitForFunction(
          (selector) => document.querySelector(selector)?.hasAttribute("data-fade-top"),
          selector,
        );
        expect(await list.getAttribute("data-fade-bottom")).not.toBeNull();
        if (process.env.FAST_CHECKS_OUT) {
          await page.screenshot({
            path: path.join(
              process.env.FAST_CHECKS_OUT,
              `${entry}-${variant}-${selector.replace(/[^a-z0-9-]/gi, "_")}-overflow.png`,
            ),
          });
        }
        await list.evaluate((node) => {
          node.scrollTop = node.scrollHeight;
        });
        await page.waitForFunction(
          (selector) => !document.querySelector(selector)?.hasAttribute("data-fade-bottom"),
          selector,
        );
        expect(await list.getAttribute("data-fade-top")).not.toBeNull();
        // Filtering down to one result removes both fades without another scroll gesture.
        if (entry === "agent-pane.project-chooser") {
          await page.locator('[role="combobox"]').fill("review-40");
          await page.waitForFunction((selector) => {
            const node = document.querySelector(selector);
            return (
              node &&
              node.scrollHeight <= node.clientHeight &&
              !node.hasAttribute("data-fade-top") &&
              !node.hasAttribute("data-fade-bottom")
            );
          }, selector);
          expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).toBe("none");
        }
      } finally {
        await page.close();
      }
    });
  }
});
