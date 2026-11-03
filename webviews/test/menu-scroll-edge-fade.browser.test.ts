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
    [
      "ui.secondary-list-overflow",
      "checks",
      ".acpmux-pr-status > .ui-popup-scroll, .acpmux-pr-status.ui-scroll-edge-fade",
      420,
      1000,
    ],
    ["ui.secondary-list-overflow", "rules", ".acpmux-rules-list", 420, 1000],
    ["ui.secondary-list-overflow", "people", ".lg-picker-rows", 420, 1000],
    [
      "ui.menu",
      "overflowing",
      ".menu-gallery-popup > .ui-popup-scroll, .menu-gallery-popup.ui-scroll-edge-fade",
      320,
      640,
    ],
    [
      "ui.context-menu",
      "overflowing",
      ".ui-context-menu > .ui-popup-scroll, .ui-context-menu.ui-scroll-edge-fade",
      320,
      640,
    ],
    ["ui.select", "overflowing", ".ui-select-popup > .ui-popup-scroll, .ui-select-popup.ui-scroll-edge-fade", 320, 640],
    [
      "pages.icon-picker",
      "categories",
      ".icon-category-menu > .ui-popup-scroll, .icon-category-menu.ui-scroll-edge-fade",
      320,
      640,
    ],
    ["agent-pane.project-chooser", "long-no-actions", ".ui-combobox-list", 320, 640],
    ["agent-pane.composer-context", "folder-long-list", ".ui-combobox-viewport", 320, 640],
    ["agent-pane.composer-context", "folder-long-list", ".ui-combobox-pinned", 240, 640],
    ["agent-pane.composer-context", "environment-picker-fleet", ".acpmux-env-popover .ui-combobox-list", 320, 640],
    ["agent-pane.add-project-panel", "long-directory", ".acpmux-add-project-list", 320, 640],
    ["new-tab.quick-model-menu", "short-more-models", ".acpmux-quick-body", 320, 640],
    ["new-tab.quick-model-menu", "plain-overflow", ".ui-popup-scroll", 320, 640],
    [
      "agent-pane.slash-menu",
      "overflowing",
      ".acpmux-slash-menu > .ui-popup-scroll, .acpmux-slash-menu.ui-scroll-edge-fade",
      320,
      640,
    ],
    [
      "agent-pane.composer",
      "slash-menu-full",
      ".acpmux-slash-menu > .ui-popup-scroll, .acpmux-slash-menu.ui-scroll-edge-fade",
      320,
      640,
    ],
    [
      "agent-pane.new-tab-page",
      "omnibar-overflow",
      ".acpmux-omni > .ui-popup-scroll, .acpmux-omni.ui-scroll-edge-fade",
      320,
      640,
    ],
    [
      "agent-pane.file-picker-loading",
      "mentions-overflow",
      ".acpmux-mention-menu > .ui-popup-scroll, .acpmux-mention-menu.ui-scroll-edge-fade",
      420,
      1000,
    ],
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
        expect(
          await list.evaluate((node) => {
            const maskedGlass: string[] = [];
            for (let parent: Element | null = node; parent; parent = parent.parentElement) {
              if (parent.classList.contains("ui-glass") && getComputedStyle(parent).maskImage !== "none") {
                maskedGlass.push(parent.className);
              }
            }
            return maskedGlass;
          }),
        ).toEqual([]);
        const glass = list.locator(
          "xpath=ancestor::*[contains(concat(' ', normalize-space(@class), ' '), ' ui-glass ')][1]",
        );
        if (await glass.count()) {
          expect(await glass.evaluate((node) => getComputedStyle(node).boxShadow)).not.toBe("none");
        }
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
  test("a one-pixel scroll rounding difference leaves the final row and popup fully opaque", async () => {
    const page = await open("ui.menu", "open", 420, 640);
    try {
      const shell = page.locator(".menu-gallery-popup");
      const list = page.locator(".menu-gallery-popup > .ui-popup-scroll, .menu-gallery-popup.ui-scroll-edge-fade");
      await list.waitFor();
      await list.evaluate((node) => {
        const el = node as HTMLElement;
        el.style.flex = "none";
        el.style.boxSizing = "content-box";
        el.style.paddingBlock = "0";
        el.style.height = "auto";
        const height = el.scrollHeight;
        el.style.height = `${height - 1}px`;
        el.scrollTop = 0;
      });
      await page.waitForFunction(() => {
        const node = document.querySelector(
          ".menu-gallery-popup > .ui-popup-scroll, .menu-gallery-popup.ui-scroll-edge-fade",
        );
        return node && node.scrollHeight - node.clientHeight === 1;
      });
      // A resize is observed asynchronously; the next animation frame follows observer delivery.
      await list.evaluate(
        () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
      );
      expect(await list.getAttribute("data-fade-bottom")).toBeNull();
      expect(await list.evaluate((node) => getComputedStyle(node).maskImage)).toBe("none");
      expect(await shell.evaluate((node) => getComputedStyle(node).maskImage)).toBe("none");
    } finally {
      await page.close();
    }
  });

  test("a submenu remains reachable across the inner scrolling viewport", async () => {
    const page = await open("ui.menu", "open", 420, 640);
    try {
      await page.getByRole("menuitem", { name: "More actions", exact: true }).focus();
      await page.keyboard.press("ArrowRight");
      const row = page.getByRole("menuitem", { name: "Rename", exact: true });
      await row.waitFor();
      await row.hover();
      await row.click();
      expect(await page.getByTestId("menu-gallery-receipt").textContent()).toContain("Rename");
    } finally {
      await page.close();
    }
  });
});
