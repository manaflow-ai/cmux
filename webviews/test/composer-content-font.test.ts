// Leo, 2026-10-28: "leo make sure font size everywhere (like text input area) is customizable".
// Exercise the real composer and transcript at the Chat Display size, in both themes and contexts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-content-font.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const capture = process.env.CMUX_FONT_CAPTURE_DIR;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", {
      browser,
      params: { variant: "font-size-chat-21" },
    });
    if (capture) await mkdir(capture, { recursive: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const context of ["chat", "new-chat", "new-tab"]) {
    for (const theme of ["light", "dark"]) {
      test(`${context} ${theme}: content follows the chosen font size`, async () => {
        const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
        try {
          const port = (vite.httpServer!.address() as { port: number }).port;
          await page.goto(
            `http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", {
              variant: `font-size-${context}-21`,
              theme: theme === "light" ? "Apple System Colors Light" : "Apple System Colors",
            })}`,
          );
          await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
          await page
            .locator(context === "new-tab" ? ".nt-field" : ".acpmux-md code")
            .first()
            .waitFor();
          if (capture) await page.screenshot({ path: path.join(capture, `${context}-${theme}.png`) });
          for (const size of [21, 14, 28]) {
            await page.evaluate(async (size) => {
              const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
              const { setChatDisplay } = await import(modulePath);
              setChatDisplay({ "agentPane.display.font.size": size });
            }, size);
            const font = async (selector: string) =>
              page
                .locator(selector)
                .first()
                .evaluate((element) => parseFloat(getComputedStyle(element).fontSize));
            if (context === "new-tab") {
              expect(await font(".nt-field")).toBeCloseTo(size, 2);
              continue;
            }
            expect(await font(".acpmux-md")).toBeCloseTo(size, 2);
            expect(await font(".acpmux-md h3")).toBeCloseTo(size, 2);
            expect(await font(".acpmux-md code")).toBeCloseTo((size * 13) / 14, 2);
            expect(await font(".acpmux-md pre")).toBeCloseTo((size * 12) / 14, 2);
            expect(await font(".acpmux-md pre code")).toBeCloseTo((size * 12) / 14, 2);
            if (context === "chat") {
              expect(await font(".cv-h1")).toBeCloseTo(size * 1.5, 2);
              expect(await font(".cv-table")).toBeCloseTo(size * 0.875, 2);
            }
          }
        } finally {
          await page.close();
        }
      });
    }
  }
});
