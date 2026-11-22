// cmux-web-test-timeout: 300
// l10n-allow-file: browser test diagnostics, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("settings-sidebar-more-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>>;
  // The sidebar's More (one settings area, David Beyer 2026-11-20): its links open below its header
  // in flow, and the section above it never moves.
  const group = '[data-sidebar-section="more"] .sidebar-more-links';
  const parent = ".sidebar-more";
  const appearance = '[data-section-link="appearance"]';

  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmGalleryFrame(vite, "pages.settings", { params: { variant: "general" } });
  }, 200_000);
  afterAll(async () => vite?.close());

  // The gallery sets its media preferences from the frame URL.
  async function open(page: Page, variant: string, { width = 900, reducedMotion = false } = {}) {
    const port = (vite.httpServer!.address() as { port: number }).port;
    await page.goto(
      `http://127.0.0.1:${port}${galleryFrame("pages.settings", {
        variant,
        width,
        height: 640,
        reducedMotion: reducedMotion ? 1 : undefined,
      })}`,
    );
    await page.waitForSelector(".settings[data-page-shown]");
    await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryReady));
  }

  for (const engine of [chromium, webkit]) {
    test(`${engine.name()}: More's links grow in flow while it opens and closes`, async () => {
      const browser = await engine.launch({ headless: true, timeout: 30_000 });
      try {
        const page = await browser.newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "no-preference" });
        await open(page, "general");
        // Sample the actual CSS transition at its midpoint and end. Pausing the animation avoids
        // asserting against how quickly the test runner can read two frames.
        const measure = (click: string) =>
          page.evaluate(
            ({ group, click }) => {
              const rows = document.querySelector<HTMLElement>(group)!;
              const height = () => rows.getBoundingClientRect().height;
              const start = height();
              return new Promise<[number, number, number]>((resolve) => {
                const onRun = (event: TransitionEvent) => {
                  if (event.propertyName !== "grid-template-rows") return;
                  rows.removeEventListener("transitionrun", onRun);
                  const animation = rows
                    .getAnimations()
                    .find(
                      (animation) =>
                        animation instanceof CSSTransition && animation.transitionProperty === event.propertyName,
                    )!;
                  const duration = Number(animation.effect!.getComputedTiming().duration);
                  animation.pause();
                  animation.currentTime = duration / 2;
                  const midpoint = height();
                  animation.finish();
                  resolve([start, midpoint, height()]);
                };
                rows.addEventListener("transitionrun", onRun);
                document.querySelector<HTMLElement>(click)!.click();
              });
            },
            { group, click },
          );

        const above = () => page.locator(appearance).boundingBox();
        const before = await above();
        const [closed, opening, expanded] = await measure(parent);
        expect(closed).toBe(0);
        expect(opening).toBeGreaterThan(closed);
        expect(opening).toBeLessThan(expanded);
        const [, closing, collapsed] = await measure(parent);
        expect(closing).toBeGreaterThan(collapsed);
        expect(closing).toBeLessThan(expanded);
        expect(collapsed).toBe(closed);
        expect(await above()).toEqual(before);
        expect(await page.locator(group).getAttribute("inert")).not.toBeNull();
      } finally {
        await browser.close();
      }
    }, 30_000);
  }

  test("deep links open fully, and both motion preferences can turn off the transition", async () => {
    const browser = await webkit.launch({ headless: true, timeout: 30_000 });
    try {
      const page = await browser.newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "no-preference" });
      await open(page, "devices");
      const children = page.locator(group);
      const height = () => children.evaluate((element) => element.getBoundingClientRect().height);
      const transitions = () => children.evaluate((element) => getComputedStyle(element).transitionProperty);
      expect(await height()).toBeGreaterThan(0);
      expect(await children.evaluate((element) => element.getAnimations().length)).toBe(0);

      await page.evaluate(() => {
        document.documentElement.dataset.cmuxMotion = "off";
      });
      expect(await transitions()).toBe("all");
      await page.locator(parent).click();
      expect(await height()).toBe(0);

      await open(page, "general", { reducedMotion: true });
      expect(await transitions()).not.toContain("grid-template-rows");
      await page.locator(parent).click();
      expect(await height()).toBeGreaterThan(0);
      expect(await children.evaluate((element) => element.getAnimations().length)).toBe(0);
    } finally {
      await browser.close();
    }
  });

  test("holding a hovered sidebar link keeps its fill and animates its contents", async () => {
    const browser = await webkit.launch({ headless: true, timeout: 30_000 });
    try {
      const page = await browser.newPage({ viewport: { width: 900, height: 640 }, reducedMotion: "no-preference" });
      await open(page, "devices");
      const sounds = page.locator('[data-section-link="devices"]');
      const theme = page.locator('[data-section-link="keys"]');
      const content = (link: typeof theme) => link.locator(".section-link-content");
      const fill = (link: typeof theme) => content(link).evaluate((row) => getComputedStyle(row).backgroundColor);
      const scale = (link: typeof theme) =>
        content(link).evaluate(async (row) => {
          await Promise.all(row.getAnimations().map((animation) => animation.finished));
          const value = getComputedStyle(row).scale;
          return value === "none" ? 1 : Number(value);
        });
      const selected = await fill(sounds);
      await sounds.hover();
      expect(await fill(sounds)).toBe(selected);

      await theme.hover();
      const hovered = await fill(theme);
      const hitArea = await theme.boundingBox();
      expect(hovered).not.toBe(selected);
      await page.mouse.down();
      expect(await fill(theme)).toBe(hovered);
      expect(await scale(theme)).toBeLessThan(1);
      expect(await theme.boundingBox()).toEqual(hitArea);
      await page.mouse.up();
      await page.waitForSelector('[data-section-link="keys"][aria-current="page"]');
      expect(await fill(theme)).toBe(selected);
      expect(await scale(theme)).toBe(1);

      await open(page, "devices", { reducedMotion: true });
      await theme.hover();
      await page.mouse.down();
      expect(await scale(theme)).toBe(1);
      await page.mouse.up();
    } finally {
      await browser.close();
    }
  });

  test("in Subtle Tone the cutout follows the selection on release", async () => {
    const browser = await webkit.launch({ headless: true, timeout: 30_000 });
    try {
      const page = await browser.newPage({ viewport: { width: 900, height: 640 } });
      await open(page, "general");
      await page.evaluate(() => {
        const style = document.documentElement.style;
        style.setProperty("--cmux-chrome-tone", "1");
        style.setProperty("--cmux-folder-fill", "transparent");
      });
      const general = page.locator('[data-section-link="general"]');
      const row = page.locator(appearance);
      const cutout = (link: typeof row) => link.evaluate((element) => getComputedStyle(element, "::before").content);
      const selected = await cutout(general);
      expect(selected).not.toBe("none");

      await row.hover();
      expect(await cutout(row)).toBe("none");
      await page.mouse.down();
      expect(await cutout(row)).toBe("none");
      expect(await cutout(general)).toBe(selected);
      await page.mouse.up();
      await page.waitForSelector(appearance + '[aria-current="page"]');
      expect(await cutout(row)).toBe(selected);
    } finally {
      await browser.close();
    }
  });

  test("a narrow pane keeps More and its links in the scrollable category strip", async () => {
    const browser = await webkit.launch({ headless: true, timeout: 30_000 });
    try {
      const page = await browser.newPage({ viewport: { width: 480, height: 640 } });
      await open(page, "general", { width: 480 });
      await page.locator(parent).click();
      const keys = page.locator('[data-section-link="keys"]');
      await keys.click();
      expect(await keys.getAttribute("aria-current")).toBe("page");
      expect(await page.locator('[data-section="keys"]').count()).toBe(1);
    } finally {
      await browser.close();
    }
  });
});
