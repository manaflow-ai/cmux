// Observe the same real New Tab fixture with the checked-out stylesheet. For baseline captures,
// substitute exact base screen.css externally and set CMUX_UI_CAPTURE_PHASE=before. This test
// never emulates the baseline with inline layout overrides. Both phases log geometry and capture
// before asserting; only the fixed phase requires containment and full-name tooltips.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-strip-overflow.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let page: Page | undefined;
  const captureDir = process.env.CMUX_UI_CAPTURE_DIR;
  const phase = process.env.CMUX_UI_CAPTURE_PHASE ?? "after";
  if (phase !== "before" && phase !== "after") throw new Error(`Unknown capture phase: ${phase}`);
  // This fixture types a real address without changing the popover's CSS or width.
  const variant = "typed-address";
  const browserLabel = "Nouvel onglet de navigateur";

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.new-tab", { browser, params: { variant } });
  });

  afterAll(async () => {
    await page?.close();
    await browser?.close();
    await vite?.close();
  });

  const cases = [320, 760].flatMap((width) =>
    (["light", "dark"] as const).map((colorScheme) => ({ width, colorScheme })),
  );
  for (const { width, colorScheme } of cases) {
    test(`${colorScheme}: French quick actions at ${width}px (${phase})`, async () => {
      page = await browser!.newPage({ viewport: { width, height: 620 }, colorScheme });
      try {
        const url = galleryFrame("agent-pane.new-tab", {
          variant,
          frame: "component",
          width,
          height: 620,
          locale: "fr",
          colorScheme,
          theme: colorScheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        });
        await page.goto(`http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${url}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".nt-create-strip-item").first().waitFor();
        // The gallery imports the pane language store before installing its catalog. Refresh it
        // through the app's language-change boundary once the catalog is available.
        await page.evaluate(() => window.dispatchEvent(new Event("languagechange")));
        await page.waitForFunction(
          (label) => [...document.querySelectorAll(".nt-create-strip-item")].some((item) => item.textContent === label),
          browserLabel,
        );
        await page.evaluate(() => document.fonts.ready);
        // createStripFit.ts measures the labels and sets data-icons-only from its ResizeObserver;
        // French needs icons at 320px and reads in full at 760px. Wait for that state to settle.
        const iconsOnly = width <= 320;
        await page.waitForFunction(
          (icons) => document.querySelector(".nt-create-strip")?.hasAttribute("data-icons-only") === icons,
          iconsOnly,
        );
        const result = await page.evaluate(() => {
          const rows = document.querySelector<HTMLElement>(".nt-rows")!;
          const viewport = rows.getBoundingClientRect();
          return {
            scrollWidth: rows.scrollWidth,
            clientWidth: rows.clientWidth,
            items: [...rows.querySelectorAll<HTMLElement>(".nt-create-strip-item")].map((item) => {
              const rect = item.getBoundingClientRect();
              const glyph = item.querySelector<HTMLElement>(".nt-row-glyph")?.getBoundingClientRect();
              const title = item.querySelector<HTMLElement>(".nt-row-title")!;
              // Icon-only hides every title visually but keeps it measurable (screen.css).
              const labelShown = !item.closest(".nt-create-strip")!.hasAttribute("data-icons-only");
              return {
                left: rect.left,
                right: rect.right,
                top: rect.top,
                width: rect.width,
                height: rect.height,
                text: item.textContent,
                label: item.getAttribute("aria-label"),
                tooltip: item.getAttribute("title") ?? item.getAttribute("data-tooltip"),
                labelShown,
                // A label that shows but is wider than its box is cut with an ellipsis.
                truncated: labelShown && title.scrollWidth > title.clientWidth + 1,
                role: item.getAttribute("role"),
                glyphWidth: glyph?.width ?? 0,
                glyphHeight: glyph?.height ?? 0,
                hit: item.contains(document.elementFromPoint(rect.left + rect.width / 2, rect.top + rect.height / 2)),
              };
            }),
            viewport: { left: viewport.left, right: viewport.right },
          };
        });
        console.log(`NEW_TAB_STRIP ${JSON.stringify({ phase, colorScheme, ...result })}`);
        if (captureDir) {
          await mkdir(captureDir, { recursive: true });
          await page.screenshot({
            path: path.join(captureDir, `new-tab-strip-${phase}-${width}-${colorScheme}.png`),
            animations: "disabled",
          });
        }

        expect(result.items).toHaveLength(3);
        expect(result.items.map((item) => item.text)).toEqual(["Nouveau terminal", browserLabel, "Nouveau chat"]);
        for (const item of result.items) {
          expect(item.role).toBe("option");
          expect(item.top).toBeCloseTo(result.items[0]!.top, 0);
          expect(item.width).toBeGreaterThan(0);
          expect(item.height).toBeGreaterThan(0);
          expect(item.glyphWidth).toBeGreaterThan(0);
          expect(item.glyphHeight).toBeGreaterThan(0);
        }
        if (phase === "before") return;
        expect(result.scrollWidth).toBeLessThanOrEqual(result.clientWidth + 1);
        for (const item of result.items) {
          expect(item.left).toBeGreaterThanOrEqual(result.viewport.left - 1);
          expect(item.right).toBeLessThanOrEqual(result.viewport.right + 1);
          expect(item.hit).toBe(true);
          expect(item.label).toBe(item.text);
          // A label shows whole or not at all: at 320px the actions are icon-only, wide they read in full.
          expect(item.truncated).toBe(false);
          expect(item.labelShown).toBe(!iconsOnly);
        }
        // A label that reads in full needs no tooltip (#20375, ui/titleTooltips.ts repeatsLabel);
        // an icon-only action shows its name in the shared tooltip.
        if (!iconsOnly) return;
        const browserAction = page.locator(`.nt-create-strip-item[aria-label="${browserLabel}"]`);
        await browserAction.hover();
        await page.waitForFunction(
          (label) =>
            [...document.querySelectorAll<HTMLElement>(".ui-tooltip-text")].some(
              (tip) => tip.textContent === label && tip.getBoundingClientRect().height > 0,
            ),
          browserLabel,
        );
        expect(await browserAction.getAttribute("data-tooltip")).toBe(browserLabel);
        expect(await page.locator(".ui-tooltip-text:visible").textContent()).toBe(browserLabel);
      } finally {
        await page.close();
        page = undefined;
      }
    });
  }
});
