// cmux-web-test-timeout: 600
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";

await requireBrowserLane("menu-health-papercuts.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const scenes = [
    ["agent-pane.changes-git-actions", "include-new", 480, 520],
    ["agent-pane.changes-git-actions", "keyboard", 480, 520],
    ["pages.settings", "font-picker", 1000, 760],
    ["viewer-empty.path-picker", "rtl", 620, 620],
  ] as const;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const [entry, variant] of scenes) await warmGalleryFrame(vite, entry, { browser, params: { variant } });
    await warmGalleryFrame(vite, "agent-pane.composer-context", { browser, params: { variant: "repo-worktrees" } });
  }, 240_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("filtering worktrees keeps the search field and list top still in a short popup", async () => {
    const page = await browser.newPage({ viewport: { width: 620, height: 180 }, deviceScaleFactor: 2 });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-context", {
          variant: "repo-worktrees",
          width: 620,
          height: 180,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const field = page.locator(".acpmux-folder-popover .acpmux-location-search");
      const list = page.locator(".acpmux-folder-popover .ui-combobox-list");
      const beforeField = await field.boundingBox();
      const beforeList = await list.boundingBox();
      expect(beforeField).not.toBeNull();
      expect(beforeList).not.toBeNull();
      await field.pressSequentially("unread");
      await page.waitForFunction(() => !!document.querySelector(".acpmux-location-row[data-worktree]"));
      // ResizeObserver and the popup positioner must both have seen the filtered list.
      await page.evaluate(
        () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
      );
      const afterField = await field.boundingBox();
      const afterList = await list.boundingBox();
      expect(afterField).not.toBeNull();
      expect(afterList).not.toBeNull();
      expect(Math.abs(afterField!.height - beforeField!.height)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(afterField!.y - beforeField!.y)).toBeLessThanOrEqual(0.5);
      expect(Math.abs(afterList!.y - beforeList!.y)).toBeLessThanOrEqual(0.5);
      expect(await field.inputValue()).toBe("unread");
      expect(await page.locator(".acpmux-location-row[data-worktree]").count()).toBeGreaterThan(0);
    } finally {
      await page.close();
    }
  });

  test("a short folder popup keeps its first two results visible without scrolling on ArrowDown", async () => {
    const page = await browser.newPage({ viewport: { width: 620, height: 180 }, deviceScaleFactor: 2 });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-context", {
          variant: "lane-checkouts",
          width: 620,
          height: 180,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      const field = page.locator(".acpmux-folder-popover .acpmux-location-search");
      const viewport = page.locator(".acpmux-folder-popover .ui-combobox-viewport");
      const options = viewport.locator('[role="option"]');
      expect(await options.count()).toBeGreaterThan(2);
      const bounds = await viewport.boundingBox();
      expect(bounds).not.toBeNull();
      const initialScroll = await viewport.evaluate((node) => node.scrollTop);
      for (const index of [0, 1]) {
        const option = options.nth(index);
        const before = await option.boundingBox();
        expect(before).not.toBeNull();
        expect(before!.y).toBeGreaterThanOrEqual(bounds!.y - 0.5);
        expect(before!.y + before!.height).toBeLessThanOrEqual(bounds!.y + bounds!.height + 0.5);
        await field.press("ArrowDown");
        await page.waitForFunction(
          (id) => document.getElementById(id!)?.hasAttribute("data-highlighted"),
          await option.getAttribute("id"),
        );
        await page.evaluate(
          () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
        );
        expect(await viewport.evaluate((node) => node.scrollTop)).toBe(initialScroll);
      }
      // Navigation must still reveal a result below the viewport.
      const third = options.nth(2);
      const hidden = await third.boundingBox();
      expect(hidden).not.toBeNull();
      expect(hidden!.y + hidden!.height).toBeGreaterThan(bounds!.y + bounds!.height);
      await field.press("ArrowDown");
      await page.waitForFunction(
        (id) => document.getElementById(id!)?.hasAttribute("data-highlighted"),
        await third.getAttribute("id"),
      );
      await page.evaluate(
        () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
      );
      expect(await viewport.evaluate((node) => node.scrollTop)).toBeGreaterThan(initialScroll);
      const revealed = await third.boundingBox();
      expect(revealed).not.toBeNull();
      expect(revealed!.y).toBeGreaterThanOrEqual(bounds!.y - 0.5);
      expect(revealed!.y + revealed!.height).toBeLessThanOrEqual(bounds!.y + bounds!.height + 0.5);
    } finally {
      await page.close();
    }
  });

  test("expanding a repository in a short folder popup keeps painted results still", async () => {
    const page = await browser.newPage({ viewport: { width: 620, height: 180 }, deviceScaleFactor: 2 });
    try {
      const { port } = vite.httpServer!.address() as { port: number };
      await page.goto(
        `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-context", {
          variant: "lane-checkouts-open",
          width: 620,
          height: 180,
        })}`,
      );
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      expect(await page.locator(".acpmux-location-row[data-worktree]").count()).toBeGreaterThan(0);
      const expansion = await page.evaluate(() =>
        window.cmuxGalleryPlayReport!.steps.find((step) => step.step === "press ArrowRight"),
      );
      expect(expansion).toBeDefined();
      // A clipped fragment of the next project must not disappear on expansion either:
      // unchanged boxes alone miss this shift because that row ends outside the viewport.
      expect(Math.max(expansion!.layoutShift, expansion!.boxShift ?? 0)).toBeLessThanOrEqual(0.0005);
    } finally {
      await page.close();
    }
  });

  for (const [entry, variant, width, height] of scenes) {
    test(`${entry}#${variant}: scope stays still and menu geometry follows its content`, async () => {
      const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 2 });
      try {
        const { port } = vite.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant, width, height })}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        if (entry === "agent-pane.changes-git-actions") {
          const steps = await page.evaluate(() =>
            window.cmuxGalleryPlayReport!.steps.map((step) => ({
              step: step.step,
              shift: Math.max(step.layoutShift, step.boxShift ?? 0),
            })),
          );
          const change = steps.find(
            (step) => step.step === (variant === "keyboard" ? "press ArrowRight" : 'click radio "All"'),
          );
          expect(change).toBeDefined();
          expect(change!.shift).toBeLessThanOrEqual(0.0005);
          if (variant === "include-new") expect(await page.locator(".acpmux-git-new-files li").count()).toBe(2);
        } else {
          const violations = await page.evaluate(() =>
            (window as unknown as { cmuxGalleryInvariants(): { rule: string; key: string }[] }).cmuxGalleryInvariants(),
          );
          const rule = entry === "pages.settings" ? "menu-fit" : "menu-label";
          expect(violations.filter((violation) => violation.rule === rule)).toEqual([]);
          if (entry === "pages.settings") {
            const bounds = await page.locator(".font-picker-panel").boundingBox();
            expect(bounds).not.toBeNull();
            expect(bounds!.x).toBeGreaterThanOrEqual(0);
            expect(bounds!.x + bounds!.width).toBeLessThanOrEqual(width);
          }
        }
        if (process.env.FAST_CHECKS_OUT)
          await page.screenshot({ path: path.join(process.env.FAST_CHECKS_OUT, `${entry}-${variant}.png`) });
      } finally {
        await page.close();
      }
    });
  }
});
