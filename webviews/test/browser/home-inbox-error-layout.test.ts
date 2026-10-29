// l10n-allow-file: public gallery fixtures and test descriptions, not shipped UI.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";
import { requireBrowserLane } from "../support/requireBrowserLane";

await requireBrowserLane("home-inbox-error-layout.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const root = path.resolve(import.meta.dir, "../..");
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.gallery-dev.ts"),
      server: { host: "127.0.0.1", port: 0 },
      logLevel: "error",
    });
    await vite.listen();
    base = `http://127.0.0.1:${(vite.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.home-lists", { browser, timeoutMs: 120_000 });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const look of ["list", "compact", "grouped"] as const) {
    for (const colorScheme of ["light", "dark"] as const) {
      for (const width of [320, 560]) {
        test(`refused inbox answer preserves ${look} rows in ${colorScheme} at ${width}px`, async () => {
          const page = await browser.newPage({ viewport: { width, height: 1000 } });
          try {
            const variant = look === "list" ? "refusal-ready" : `refusal-ready-${look}`;
            await page.goto(
              `${base}${galleryFrame("agent-pane.home-lists", {
                variant,
                width,
                height: 1000,
                colorScheme,
                locale: width === 320 ? "en-XA" : "en",
                reducedMotion: 1,
              })}`,
            );
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            const rows = page.locator(".acpmux-home-inbox-row");
            const answerable = rows.filter({ has: page.locator(".acpmux-home-inbox-answers") });
            const first = answerable.first();
            const answer = first.locator(".acpmux-home-inbox-answer").first();
            await answer.scrollIntoViewIfNeeded();
            const geometry = () =>
              rows.evaluateAll((elements) =>
                elements.map((element) => {
                  const bounds = element.getBoundingClientRect();
                  return { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height };
                }),
              );
            expect(await first.getByRole("alert").count()).toBe(0);
            const before = await geometry();
            const out = process.env.CMUX_HOME_ERROR_CAPTURE_DIR;
            const capture = async (state: string) => {
              if (!out || look !== "list" || width !== 560) return;
              await mkdir(out, { recursive: true });
              await page.screenshot({ path: path.join(out, `${colorScheme}-${state}.png`) });
            };
            await capture("before");
            await answer.click();
            await first.getByRole("alert").waitFor();
            await capture("refused");
            expect(await first.getByRole("alert").innerText()).not.toBe("");
            expect(await answer.isEnabled()).toBe(true);
            expect(await geometry()).toEqual(before);
          } finally {
            await page.close();
          }
        });
      }
    }
  }
});
