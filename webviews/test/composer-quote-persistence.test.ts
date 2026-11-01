// cmux-web-test-timeout: 180
// Quote-only drafts must survive the real Composer/editor teardown with a typing paragraph below the quote.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-quote-persistence.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.composer-quote-persistence";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "ready" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const ready = async (page: Page) => {
    await page.waitForFunction(() => {
      const field = document.querySelector<MarkdownFieldElement>(".acpmux-md-field");
      return (
        document.documentElement.dataset.galleryReady === "1" &&
        !!field?.acpmuxMarkdownField &&
        !!field.querySelector("[contenteditable]")
      );
    });
  };

  for (const variant of ["empty", "draft"]) {
    test(`${variant}: save, reopen and type below a quote, then send separate Markdown paragraphs`, async () => {
      const page = await browser.newPage({ viewport: { width: 760, height: 650 } });
      try {
        const port = (vite.httpServer!.address() as { port: number }).port;
        await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "ready", frame: "component" })}`);
        await ready(page);
        if (variant === "draft") {
          await page.locator(".acpmux-md").click();
          await page.keyboard.type("I already have a draft reply.");
        }
        await page.getByRole("button", { name: "Quote selection", exact: true }).click();
        await page.locator(".acpmux-md blockquote").waitFor();
        // This calls ComposerHandle.settleDraft, then unmounts the real Composer and editor.
        await page.getByRole("button", { name: "Save and close", exact: true }).click();
        await page.locator(".acpmux-md").waitFor({ state: "detached" });
        await page.getByRole("button", { name: "Reopen", exact: true }).click();
        await ready(page);
        await page.locator(".acpmux-md blockquote").waitFor();
        await page.evaluate(() => {
          const field = document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!;
          field.setCaret(Number.MAX_SAFE_INTEGER);
          field.focus();
        });
        await page.keyboard.type("My reply stays outside.");
        const editor = page.locator(".acpmux-md");
        expect(await editor.locator("blockquote").textContent()).toBe("Keep this quote separate.");
        expect(await editor.locator(":scope > p").last().textContent()).toBe("My reply stays outside.");
        const expected = `${variant === "draft" ? "I already have a draft reply.\n\n" : ""}> Keep this quote separate.\n\nMy reply stays outside.`;
        expect(
          await page.evaluate(() =>
            document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!.value(),
          ),
        ).toBe(expected);
        await page.keyboard.press("Enter");
        await page.waitForFunction(() => !!document.querySelector("[data-sent-markdown]")?.textContent);
        expect(await page.locator("[data-sent-markdown]").textContent()).toBe(expected);
      } finally {
        await page.close();
      }
    });
  }
});
