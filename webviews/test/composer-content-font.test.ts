// Leo, 2026-10-28: "leo make sure font size everywhere (like text input area) is customizable".
// Exercise the real composer and transcript at the Chat Display size, in both themes and contexts.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
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

  test("queued prompt and its editor follow the chosen content size", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 640 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", { variant: "queued-images" })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1");
      await page.evaluate(async () => {
        const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
        const { setChatDisplay } = await import(modulePath);
        setChatDisplay({ "agentPane.display.font.size": 28 });
      });
      const row = page.locator(".acpmux-queued").first();
      expect(
        await row.locator(".acpmux-queued-text").evaluate((element) => parseFloat(getComputedStyle(element).fontSize)),
      ).toBeCloseTo(28, 2);
      await row.focus();
      await row.press("Enter");
      const edit = page.locator(".acpmux-queued-edit");
      await edit.waitFor();
      expect(await edit.evaluate((element) => parseFloat(getComputedStyle(element).fontSize))).toBeCloseTo(28, 2);
    } finally {
      await page.close();
    }
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
          if (capture) {
            for (const size of [14, 21, 28]) {
              await page.evaluate(async (size) => {
                const modulePath = "/gallery/src/agent-session/acpmux/chatDisplay.ts";
                const { setChatDisplay } = await import(modulePath);
                setChatDisplay({ "agentPane.display.font.size": size });
              }, size);
              await page.screenshot({ path: path.join(capture, `${context}-${theme}-${size}.png`) });
            }
          }
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
          // Shell mode is another editor in the same box and must keep the chosen size.
          if (context === "new-tab") {
            const prompt = page.locator(".nt-field");
            await prompt.fill("");
            await prompt.press("!");
          } else {
            // Use the editor's typing API: DOM fill can race ProseMirror's mutation observer,
            // leaving its document nonempty when the following beforeinput arrives.
            await page
              .locator(".acpmux-composer-prompt")
              .first()
              .evaluate((element) => {
                const field = (element as MarkdownFieldElement).acpmuxMarkdownField;
                if (!field?.type("")) throw new Error("The composer editor is not ready");
                field.insertTyped("!");
              });
          }
          const shell = page.locator(
            context === "new-tab" ? ".nt-screen[data-shell] .nt-field" : ".acpmux-shell-field",
          );
          await shell.waitFor();
          expect(await shell.evaluate((element) => parseFloat(getComputedStyle(element).fontSize))).toBeCloseTo(28, 2);
        } finally {
          await page.close();
        }
      });
    }
  }
});
