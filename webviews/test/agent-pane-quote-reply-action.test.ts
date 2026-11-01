// cmux-web-test-timeout: 180
// l10n-allow-file: test fixture draft and quote text, not shipped UI.
// Quote in Reply from the native transcript menu reaches the real agent pane as the page action
// `chat.quoteReply` (AgentPaneView+ContextMenu.swift). The pane must register it and route it to
// ComposerHandle.quoteReply, so the draft already typed stays first and the quote follows it.
// Before this action existed the menu sent `chat.editPrompt`, whose restore replaced the draft.
//
// Real Chromium from Playwright on the gallery's agent pane (mock transport, synthetic draft).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import type { MarkdownFieldElement } from "../src/agent-session/acpmux/MarkdownField";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-quote-reply-action.test.ts", async () => {
  setDefaultTimeout(120_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  const entry = "agent-pane.quote-reply";
  const draft = "I already have a draft reply.";
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, entry, { browser, params: { variant: "draft" } });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the native Quote in Reply action keeps the draft and appends the quote after it", async () => {
    const page = await browser.newPage({ viewport: { width: 760, height: 500 } });
    try {
      const port = (vite.httpServer!.address() as { port: number }).port;
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(entry, { variant: "draft", frame: "component" })}`);
      await page.waitForFunction(
        (text) => {
          const field = document.querySelector<MarkdownFieldElement>(".acpmux-md-field")?.acpmuxMarkdownField;
          return document.documentElement.dataset.galleryReady === "1" && field?.value() === text;
        },
        draft,
        { timeout: 30_000 },
      );
      // The action the native menu runs (`window.cmuxAcpmuxActions?.['chat.quoteReply']?.(...)`):
      // without it the menu's call is a silent no-op and the quote never reaches the composer.
      const registered = await page.evaluate(() => {
        const actions = (window as { cmuxAcpmuxActions?: Record<string, unknown> }).cmuxAcpmuxActions;
        return typeof actions?.["chat.quoteReply"];
      });
      expect(registered).toBe("function");
      await page.evaluate(async () => {
        const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
          .cmuxAcpmuxActions!;
        await actions["chat.quoteReply"]!({ markdown: "> Please keep the review focused.\n\n" });
        await actions["chat.quoteReply"]!({ markdown: "> Then land the change.\n\n" });
      });
      await page.locator(".acpmux-md blockquote").nth(1).waitFor();
      const editor = page.locator(".acpmux-md");
      expect(await editor.locator(":scope > p").first().textContent()).toBe(draft);
      expect(await editor.locator("blockquote").allTextContents()).toEqual([
        "Please keep the review focused.",
        "Then land the change.",
      ]);
      const value = () =>
        page.evaluate(() =>
          document.querySelector<MarkdownFieldElement>(".acpmux-md-field")!.acpmuxMarkdownField!.value(),
        );
      // The Markdown the agent gets: the draft first, then each quote in the order it was picked.
      const sent = await value();
      expect(sent.startsWith(`${draft}\n\n> Please keep the review focused.`)).toBe(true);
      expect(sent.indexOf("> Then land the change.")).toBeGreaterThan(
        sent.indexOf("> Please keep the review focused."),
      );
      // The caret waits in the empty reply paragraph below the quotes, outside both of them.
      await page.keyboard.type("My reply.");
      expect(await editor.locator(":scope > p").last().textContent()).toBe("My reply.");
      expect((await value()).endsWith("> Then land the change.\n\nMy reply.")).toBe(true);
    } finally {
      await page.close();
    }
  });
});
