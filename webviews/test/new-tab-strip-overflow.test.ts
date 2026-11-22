import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { translateNewTab } from "../src/agent-session/acpmux/newtab/strings";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("new-tab-strip-overflow.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const variant = "suggestions-create";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
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
  for (const width of [320, 760]) {
    for (const colorScheme of ["light", "dark"] as const) {
      test(`${colorScheme}: searchable create rows and command shortcuts fit at ${width}px`, async () => {
        const page = await browser!.newPage({ viewport: { width, height: 620 }, colorScheme });
        try {
          const url = galleryFrame("agent-pane.new-tab", {
            variant,
            frame: "component",
            width,
            height: 620,
            locale: "fr",
            colorScheme,
          });
          const address = vite!.httpServer!.address() as { port: number };
          await page.goto(`http://127.0.0.1:${address.port}${url}`);
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page.evaluate(() => document.fonts.ready);
          const result = await page.evaluate(() => {
            const list = document.querySelector<HTMLElement>(".nt-rows")!;
            return {
              fixedCreate: document.querySelector(".nt-create") !== null,
              shortcuts: [...list.querySelectorAll<HTMLElement>(".nt-row-shortcut")].map((shortcut) => {
                const style = getComputedStyle(shortcut);
                return {
                  visible: style.opacity === "1" && style.display !== "none",
                  caps: [...shortcut.querySelectorAll("kbd")].map((cap) => cap.textContent),
                };
              }),
              overflow: list.scrollWidth > list.clientWidth + 1,
              creates: list.querySelectorAll("[data-type=create]").length,
            };
          });
          expect(result.fixedCreate).toBe(false);
          expect(result.shortcuts).toEqual([
            { visible: true, caps: ["⌃", "`"] },
            { visible: true, caps: ["⌘", "B"] },
          ]);
          expect(result.overflow).toBe(false);
          expect(result.creates).toBe(0);
          for (const kind of ["terminal", "browser", "chat"] as const) {
            const title = translateNewTab(`create.${kind}`, {}, "fr");
            await page.locator(".nt-field [contenteditable]").fill(title);
            const row = page.locator('.nt-row[data-type="create"]').filter({ hasText: title });
            await row.waitFor();
            const fit = await row.evaluate((row) => {
              const list = document.querySelector<HTMLElement>(".nt-rows")!;
              const bounds = list.getBoundingClientRect();
              const rect = row.getBoundingClientRect();
              return {
                inside: rect.left >= bounds.left - 1 && rect.right <= bounds.right + 1,
                whole: row.scrollWidth <= row.clientWidth + 1,
                overflow: list.scrollWidth > list.clientWidth + 1,
              };
            });
            expect(fit, title).toEqual({ inside: true, whole: true, overflow: false });
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
