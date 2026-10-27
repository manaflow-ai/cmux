// The prompt's context menu is a text field's (POLISH.md right-click contract, Composer): Undo and
// Redo first, the edit items and Select All, then Attach Files… and Insert Mention. Undo and Redo
// follow the prompt's own history and Select All selects the whole prompt. In Chromium on the
// gallery stage, the agent pane runs on the gallery's stand-in for the app's pane bridge.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-field-menu.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true, timeout: 30_000 })).close();
  } catch {
    console.warn("composer-field-menu: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer field menu", () => test("chromium", () => {}));
    return;
  }

  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  const stage = async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    for (let attempt = 0; ; attempt += 1) {
      await page.goto(`http://127.0.0.1:${port}${galleryFrame("agent-pane.composer", { variant: "idle" })}`);
      try {
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
          timeout: 60_000,
        });
        return page;
      } catch (error) {
        // The first load can hit Vite's dependency optimizer, which reloads the page once.
        if (attempt > 1 || !/context was destroyed|navigat/i.test(String(error))) throw error;
      }
    }
  };

  /** Opens the prompt's context menu and reads its rows: label and whether it is enabled. */
  const openMenu = async (page: Page) => {
    await page.evaluate(() => {
      const field = document.querySelector(".acpmux-md")!;
      const box = field.getBoundingClientRect();
      field.dispatchEvent(
        new MouseEvent("contextmenu", {
          bubbles: true,
          cancelable: true,
          clientX: box.left + 40,
          clientY: box.top + 12,
        }),
      );
    });
    await page.waitForSelector(".ui-context-menu [role=menuitem]");
    return page.$$eval(".ui-context-menu [role=menuitem], .ui-context-menu [role=menuitemcheckbox]", (rows) =>
      rows.map((row) => `${row.textContent?.trim()}${row.hasAttribute("disabled") ? " (off)" : ""}`),
    );
  };
  const pick = async (page: Page, label: string) => {
    await page
      .locator(".ui-context-menu [role=menuitem], .ui-context-menu [role=menuitemcheckbox]", { hasText: label })
      .click();
    await page.waitForSelector(".ui-context-menu", { state: "detached" });
  };
  const prompt = (page: Page) => page.locator(".acpmux-md[contenteditable='true']").innerText();

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, "agent-pane.composer", { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  test("the prompt's menu offers Undo, Redo and Select All, and they act on the prompt", async () => {
    const page = await stage();
    await page.click(".acpmux-md[contenteditable='true']");
    await page.keyboard.press("ControlOrMeta+A");
    await page.keyboard.press("Backspace");
    await page.keyboard.type("Rename the retry helper");
    const typed = await openMenu(page);
    await pick(page, "Select All");
    const selected = await page.evaluate(() => getSelection()?.toString().trim());
    await page.keyboard.press("ArrowRight");
    await openMenu(page);
    await pick(page, "Undo");
    const undone = await prompt(page);
    const afterUndo = await openMenu(page);
    await pick(page, "Redo");
    const redone = await prompt(page);
    expect({ typed, selected, undone: undone.trim() !== "Rename the retry helper", afterUndo, redone }).toEqual({
      typed: [
        "Undo",
        "Redo (off)",
        "Cut (off)",
        "Copy (off)",
        "Paste",
        "Paste as Plain Text",
        "Select All",
        "Attach Files…",
        "Insert Mention",
        "✓Scroll to bottom when I send",
      ],
      selected: "Rename the retry helper",
      undone: true,
      afterUndo: expect.arrayContaining(["Redo"]),
      redone: expect.stringContaining("Rename the retry helper"),
    });
    await page.close();
  });

  test("the composer menu toggles send-to-bottom and keeps its checked state", async () => {
    const page = await stage();
    expect(await openMenu(page)).toContain("✓Scroll to bottom when I send");
    await pick(page, "Scroll to bottom when I send");
    expect(await openMenu(page)).toContain("Scroll to bottom when I send");
    const toggle = page.getByRole("menuitemcheckbox", { name: "Scroll to bottom when I send" });
    expect(await toggle.getAttribute("aria-checked")).toBe("false");
    await pick(page, "Scroll to bottom when I send");
    expect(await openMenu(page)).toContain("✓Scroll to bottom when I send");
    expect(await toggle.getAttribute("aria-checked")).toBe("true");
    await page.close();
  });
});
