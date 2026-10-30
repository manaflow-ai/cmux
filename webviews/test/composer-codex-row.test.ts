// Codex keeps its mode/model/context controls beside + and the send controls inside the box.
// Claude keeps the quiet footer. Captures are gallery fixtures, never private reference images.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-codex-row.test.ts", async () => {
  if (!(await probeEngineOrSkip("composer-codex-row", "chromium", chromium))) return;
  setDefaultTimeout(180_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const out = path.resolve(process.env.COMPOSER_CAPTURE_DIR ?? path.join(webviews, "artifacts/codex-composer"));
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer-look", { browser, params: { variant: "claude-chat" } });
    mkdirSync(out, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const look of ["claude", "codex"])
    for (const theme of ["light", "dark"])
      for (const width of [720, 420])
        test(`${look} ${theme} ${width}: controls belong to their look's row`, async () => {
          const page = await browser.newPage({ viewport: { width, height: 560 }, deviceScaleFactor: 2 });
          try {
            const port = (vite.httpServer!.address() as { port: number }).port;
            await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer-look", {
              variant: `${look}-chat`, theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            })}`);
            await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
            await page.evaluate(() => document.fonts.ready);
            await page.mouse.move(0, 0);
            await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))));
            const geometry = await page.evaluate(() => {
              const composer = document.querySelector(".acpmux-composer")!;
              const box = composer.querySelector(".acpmux-composer-box")!;
              const bounds = (el: Element) => {
                const r = el.getBoundingClientRect();
                return { left: r.left, right: r.right, top: r.top, bottom: r.bottom, cy: (r.top + r.bottom) / 2 };
              };
              const controls = [".acpmux-composer-plus .acpmux-picker-button", ".acpmux-access-trigger", ".acpmux-model .acpmux-picker-button", ".acpmux-context-ring", ".acpmux-mic", ".acpmux-send"].flatMap((selector) => {
                const el = composer.querySelector(selector);
                return el ? [{ selector, inside: box.contains(el), ...bounds(el) }] : [];
              });
              const bar = box.querySelector(".acpmux-composer-bar")!;
              const dots = composer.querySelector(".acpmux-composer-under");
              return { box: bounds(box), controls, bar: bounds(bar), dots: dots ? bounds(dots) : null,
                emptyAttachments: !!box.querySelector(".acpmux-attachments:empty") };
            });
            const stem = `${look}-${theme}-${width}`;
            await page.locator(".acpmux-composer").screenshot({ path: path.join(out, `${stem}.png`), animations: "disabled", caret: "hide" });
            writeFileSync(path.join(out, `${stem}.json`), JSON.stringify(geometry, null, 2));
            console.log(`COMPOSER_GEOMETRY ${stem} ${JSON.stringify(geometry)}`);
            expect(geometry.emptyAttachments).toBe(false);
            expect(geometry.controls.some((c) => c.selector.includes("acpmux-model"))).toBe(true);
            expect(geometry.controls.some((c) => c.selector.includes("acpmux-access"))).toBe(true);
            if (look === "codex") {
              expect(geometry.controls.every((c) => c.inside)).toBe(true);
              const axis = geometry.controls[0]!.cy;
              for (const control of geometry.controls) expect(Math.abs(control.cy - axis)).toBeLessThanOrEqual(0.5);
              expect(geometry.box.bottom - geometry.bar.bottom).toBeLessThanOrEqual(0.5);
              if (geometry.dots) expect(geometry.dots.top).toBeGreaterThanOrEqual(geometry.box.bottom);
            } else {
              for (const control of geometry.controls.filter((c) => /access|model|context/.test(c.selector))) expect(control.inside).toBe(false);
            }
          } finally {
            await page.close();
          }
        });
});
