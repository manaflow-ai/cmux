// An inspector pick placed in the real composer's text (composer/inlineNode.ts, ContentChip.tsx),
// opened in place: the report's scroller keeps its keys. Review of cmux#38447 at 105d5c58: "This
// focusable span lets Enter and arrows reach ProseMirror ... and the editor's Enter handler submits
// the draft." Enter, the arrows and Page Down in the opened report never send, never move the
// editor's caret, never change the draft; the arrows still scroll the report; Escape still folds it.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("ui-pick-chip-composer.browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const ENTRY = "agent-pane.composer";
  const VARIANT = "attachment-inline-caret";
  const DRAFT = "Compare this with the previous result.";
  /// A report taller than the opened scroller, so its keys have somewhere to scroll.
  const REPORT = [
    "cmux NEXT app-owned webview selection",
    "Component: span",
    "Source: unavailable",
    "Selector: .cv-li__text",
    ...Array.from({ length: 60 }, (_, index) => `Computed style ${index}: "value ${index}"`),
    'DOM: <span class="cv-li__text">the Cloud version-check and Cloud Desktop fixes;</span>',
  ].join("\n");

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.resolve(import.meta.dir, "../vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, ENTRY, { browser, params: { variant: VARIANT } });
  }, 170_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function composer(): Promise<Page> {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(ENTRY, { variant: VARIANT, width: 1000 })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 90_000,
    });
    // The pick, as the inspector pushes it, placed at the caret.
    await page.evaluate((text) => {
      window.cmuxAcpmuxComposer?.({ attachmentView: "inline" });
      window.cmuxAcpmuxBridge!.designSelection!({ id: "ui-pointer-test", name: "UI: span", text });
    }, REPORT);
    await page.waitForSelector('.acpmux-md [data-chip-kind="ui"]');
    return page;
  }

  const draft = (page: Page) =>
    page.evaluate(() => ({
      text: document.querySelector(".acpmux-md")?.textContent ?? "",
      chips: document.querySelectorAll('.acpmux-md [data-chip-kind="ui"]').length,
      user: document.querySelectorAll(".cv-user").length,
    }));

  test("the opened report keeps its keys: Enter and arrows never reach the editor; Escape folds", async () => {
    const page = await composer();
    try {
      const chip = page.locator('.acpmux-md [data-chip-kind="ui"]');
      await chip.locator("button[aria-expanded]").click();
      await page.waitForSelector('.acpmux-md [data-chip-kind="ui"][data-open]');
      // The draft with the report drawn open in it.
      const before = await draft(page);
      expect(before.chips).toBe(1);
      expect(before.text).toStartWith(DRAFT.slice(0, 12));
      expect(before.text).toEndWith("with the previous result.");
      const scroller = chip.locator(".acpmux-paste-view__text");
      await scroller.focus();
      const caret = () =>
        page.evaluate(() => {
          const selection = document.getSelection();
          return selection ? `${selection.anchorOffset}:${selection.focusOffset}` : "";
        });
      await page.keyboard.press("Enter");
      await page.keyboard.press("Shift+Enter");
      await page.keyboard.press("Backspace");
      await page.keyboard.type("x");
      expect(await draft(page)).toEqual(before);
      expect(await chip.getAttribute("data-open")).toBe("");
      // The arrows scroll the report and leave the draft and its caret alone.
      const at = await caret();
      for (let step = 0; step < 6; step += 1) await page.keyboard.press("ArrowDown");
      await page.keyboard.press("PageDown");
      expect(await scroller.evaluate((node) => node.scrollTop)).toBeGreaterThan(0);
      await page.keyboard.press("ArrowLeft");
      await page.keyboard.press("ArrowRight");
      expect(await caret()).toBe(at);
      expect(await draft(page)).toEqual(before);
      expect(await page.evaluate(() => document.activeElement?.classList.contains("acpmux-paste-view__text"))).toBe(
        true,
      );
      // Escape still folds it, focus back on its face.
      await page.keyboard.press("Escape");
      await page.waitForFunction(
        () => !document.querySelector('.acpmux-md [data-chip-kind="ui"]')?.hasAttribute("data-open"),
      );
      expect((await draft(page)).chips).toBe(1);
      expect((await draft(page)).user).toBe(before.user);
    } finally {
      await page.close();
    }
  });
});
