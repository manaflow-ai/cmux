// The New Tab popover's create strip (New terminal, New browser tab, New chat): each action's icon
// and label sit centered in its own third, and the strip's cells start on the rows' left edge at
// every interface scale (Leo 2026-11-06: "this is misaligned at the left ... have them all
// individually centered along their things?"). Real gallery fixture, checked-out stylesheet.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-strip-centered.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const captureDir = process.env.CMUX_UI_CAPTURE_DIR;
  const variant = "typed-address";

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
    await browser?.close();
    await vite?.close();
  });

  const cases = [760, 1100].flatMap((width) =>
    [1, 1.25].flatMap((interfaceScale) =>
      (["light", "dark"] as const).map((colorScheme) => ({ width, interfaceScale, colorScheme })),
    ),
  );
  for (const { width, interfaceScale, colorScheme } of cases) {
    test(`${colorScheme}: strip cells centered and on the rows' edge at ${width}px, scale ${interfaceScale}`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 620 }, colorScheme });
      try {
        const url = galleryFrame("agent-pane.new-tab", {
          variant,
          frame: "component",
          width,
          height: 620,
          interfaceScale,
          colorScheme,
          theme: colorScheme === "light" ? "Apple System Colors Light" : "Apple System Colors",
        });
        await page.goto(`http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}${url}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
        await page.locator(".nt-create-strip-item").first().waitFor();
        await page.evaluate(() => document.fonts.ready);
        await page.waitForFunction(() => !document.querySelector(".nt-create-strip")?.hasAttribute("data-icons-only"));
        const result = await page.evaluate(() => {
          const row = document.querySelector<HTMLElement>(".nt-rows > .nt-row")!;
          const rowRect = row.getBoundingClientRect();
          const rowGlyph = row.querySelector<HTMLElement>(".nt-row-glyph")!.getBoundingClientRect();
          return {
            row: { left: rowRect.left, right: rowRect.right, glyph: rowGlyph.left },
            items: [...document.querySelectorAll<HTMLElement>(".nt-create-strip-item")].map((item) => {
              const rect = item.getBoundingClientRect();
              const glyph = item.querySelector<HTMLElement>(".nt-row-glyph")!.getBoundingClientRect();
              const title = item.querySelector<HTMLElement>(".nt-row-title")!;
              // The title's text, not its box: a box that grows to fill the cell hides an off-center label.
              const range = document.createRange();
              range.selectNodeContents(title);
              const text = range.getBoundingClientRect();
              return { left: rect.left, right: rect.right, glyph: glyph.left, textRight: text.right };
            }),
          };
        });
        console.log(`NEW_TAB_STRIP_CENTERED ${JSON.stringify({ width, interfaceScale, colorScheme, ...result })}`);
        if (captureDir) {
          await mkdir(captureDir, { recursive: true });
          await page.screenshot({
            path: path.join(captureDir, `new-tab-strip-centered-${width}-${interfaceScale}-${colorScheme}.png`),
            animations: "disabled",
          });
        }
        expect(result.items).toHaveLength(3);
        // The strip spans the rows: its first cell starts and its last ends where a row does.
        expect(result.items[0]!.left).toBeCloseTo(result.row.left, 0);
        expect(result.items[2]!.right).toBeCloseTo(result.row.right, 0);
        for (const item of result.items) {
          const before = item.glyph - item.left;
          const after = item.right - item.textRight;
          expect(Math.abs(before - after)).toBeLessThanOrEqual(1);
        }
      } finally {
        await page.close();
      }
    });
  }
});
