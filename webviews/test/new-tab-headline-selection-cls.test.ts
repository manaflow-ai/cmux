// cmux-web-test-timeout: 300
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-headline-selection-cls.test.ts", async () => {
  setDefaultTimeout(300_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ["agent-pane.new-tab-headline", "agent-pane.new-tab-headline-stability"], {
      browser,
      timeoutMs: 240_000,
    });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const [width, height] of [
    [900, 800],
    [540, 420],
  ])
    for (const name of ["cmux", "composer-layout-regression-with-a-deliberately-long-project-name"])
      for (const theme of ["dark", "light"]) {
        test(`project selection and reopening keep layout stable (${theme}, ${width}, ${name})`, async () => {
          const port = (vite!.httpServer!.address() as { port: number }).port;
          const page = await browser!.newPage({
            viewport: { width: width!, height: height! },
            deviceScaleFactor: 2,
          });
          try {
            await page.goto(
              `http://127.0.0.1:${port}${galleryFrame(name === "cmux" ? "agent-pane.new-tab-headline" : "agent-pane.new-tab-headline-stability", { variant: name === "cmux" ? "on" : "long", theme: theme === "dark" ? "Apple System Colors" : "Apple System Colors Light", colorScheme: theme, width: width!, height: height! })}`,
            );
            await page.waitForFunction(() => Boolean(document.documentElement.dataset.galleryPlay));
            const headline = page.locator(".nt-headline");
            const trigger = page.locator(".nt-headline .acpmux-project-button");
            const rects = () =>
              page.evaluate(() =>
                Object.fromEntries(
                  [
                    ".nt-headline",
                    ".nt-headline-text",
                    ".nt-headline .acpmux-project-button",
                    ".nt-composer",
                    ".nt-composer .acpmux-location-label",
                    ".nt-foot .acpmux-access-trigger",
                    ".nt-foot .acpmux-location-leading",
                  ].map((selector) => {
                    const r = document.querySelector(selector)?.getBoundingClientRect();
                    return [selector, r ? { x: r.x, y: r.y, width: r.width, height: r.height } : null];
                  }),
                ),
              );
            const before = await rects();

            if (process.env.CMUX_HEADLINE_CAPTURE)
              await page.screenshot({
                path: `${process.env.CMUX_HEADLINE_CAPTURE}-${theme}-${width}-${name}-before.png`,
              });
            await trigger.click();
            const option = page.getByRole("option", { name: new RegExp("^" + name + " /") }).first();
            await option.waitFor();
            await page.evaluate(() => {
              const state = { total: 0, sources: [] as unknown[] };
              (window as unknown as { headlineShifts: typeof state }).headlineShifts = state;
              new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                  const shift = entry as PerformanceEntry & {
                    value: number;
                    sources?: {
                      node?: Node;
                      previousRect: DOMRectReadOnly;
                      currentRect: DOMRectReadOnly;
                    }[];
                  };
                  state.total += shift.value;
                  state.sources.push(
                    ...(shift.sources ?? []).map((source) => ({
                      node: (source.node as Element)?.outerHTML?.slice(0, 160) ?? source.node?.textContent,
                      parent: source.node?.parentElement?.outerHTML?.slice(0, 180),
                      previous: source.previousRect,
                      current: source.currentRect,
                    })),
                  );
                }
              }).observe({ type: "layout-shift" });
            });
            await option.click();
            await page.waitForFunction(
              (selected) => document.querySelector(".nt-headline-text")?.textContent?.includes(selected),
              name,
            );
            await page.evaluate(
              () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
            );
            const after = await rects();
            if (process.env.CMUX_HEADLINE_CAPTURE)
              await page.screenshot({
                path: `${process.env.CMUX_HEADLINE_CAPTURE}-${theme}-${width}-${name}-after.png`,
              });

            await trigger.click();
            await page.locator(".acpmux-project-menu").waitFor();
            await page.evaluate(
              () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
            );
            const shifts = await page.evaluate(
              () => (window as unknown as { headlineShifts: { total: number; sources: unknown[] } }).headlineShifts,
            );
            console.log(JSON.stringify({ theme, width, height, name, before, after, shifts }));
            expect(await headline.textContent()).toContain(name);
            expect(shifts.total).toBe(0);
            expect(after[".nt-composer"]).toEqual(before[".nt-composer"]);
            expect(after[".nt-headline"]).toEqual(before[".nt-headline"]);
            expect(after[".nt-foot .acpmux-access-trigger"]).toEqual(before[".nt-foot .acpmux-access-trigger"]);
            expect(after[".nt-foot .acpmux-location-leading"]).toEqual(before[".nt-foot .acpmux-location-leading"]);
            expect((await trigger.getAttribute("title")) ?? (await trigger.getAttribute("data-tooltip"))).toContain(
              name,
            );
            const controls = await page.locator(".nt-foot button[aria-haspopup]").evaluateAll((nodes) =>
              nodes.map((node) => {
                const { x, y, width, height } = node.getBoundingClientRect();
                return { x, y, width, height };
              }),
            );
            expect(controls.length).toBeGreaterThanOrEqual(3);
            for (const control of controls) {
              expect(control.width).toBeGreaterThan(0);
              expect(control.height).toBeGreaterThan(0);
              expect(control.x).toBeGreaterThanOrEqual(after[".nt-composer"]!.x);
              expect(control.x + control.width).toBeLessThanOrEqual(
                after[".nt-composer"]!.x + after[".nt-composer"]!.width,
              );
            }
          } finally {
            await page.close();
          }
        });
      }
});
