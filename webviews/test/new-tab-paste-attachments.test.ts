// cmux-web-test-timeout: 300
// Leo, 2026-10-19: "i cant paste in pictures in the new tab area but it works in the existing
// chats...?". The New Tab page's field took no pasted image and no dropped file: it is its own
// field, not the chat composer, and its first send carried only text. It now stages them as the
// chat composer does (the same chips, composer/attachmentIntake.tsx), and the chat it starts sends
// them with its first prompt.
//
// The pane's dev entry as a New Tab page, on the in-page mock transport. Real Chromium and WebKit
// (the app's engine); CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-paste-attachments.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-paste-attachments.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`new-tab-paste-attachments: ${engine[0]} cannot launch here`);
    }
  }
  if (engines.length === 0) {
    describe.skip("new tab paste attachments", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  /// A New Tab page, as Cmd-T opens one, on the in-page mock daemon; `classic` shows the Classic
  /// template (NewTabPage.tsx) instead of the default one (NewTabScreen.tsx).
  async function newTab(name: string, classic = false): Promise<Page> {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((classic) => {
      const newTab = {
        kind: "agent",
        hotkeys: {},
        home: "/Users/you",
        projects: [],
        ...(classic ? { template: "classic" } : {}),
      };
      Object.assign(window, {
        __cmuxNewTabContext: newTab,
        webkit: { messageHandlers: { agentSession: { postMessage: async () => ({ ok: true, value: null }) } } },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true, newTab }),
        },
      });
    }, classic);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(classic ? "input.acpmux-newtab-field" : ".nt-field").waitFor();
    return page;
  }

  /// A PNG in a DataTransfer, as a copied screenshot or image file is on the pasteboard.
  const transfer = (page: Page, file = "Screenshot.png") =>
    page.evaluateHandle(async (file) => {
      const canvas = document.createElement("canvas");
      canvas.width = 320;
      canvas.height = 200;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], file, { type: "image/png" }));
      return data;
    }, file);

  test.each(engines.map(([name]) => name))(
    "%s: an image pasted on the New Tab field shows as a chip and goes with the first prompt",
    async (name) => {
      const page = await newTab(name);
      const field = page.locator(".nt-field");
      await field.click();
      await page.keyboard.type("what is this");
      const data = await transfer(page);
      await field.evaluate(
        (node, data) =>
          node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
        data,
      );
      // The chat composer's chip, in the New Tab composer.
      await page.locator(".nt-box .acpmux-attachments .acpmux-attachment-image").waitFor();
      expect(await field.inputValue()).toBe("what is this");
      await page.keyboard.press("Enter");
      // The page became the chat; its first message carries the text and the image.
      await page.locator(".cv-user__bubble", { hasText: "what is this" }).waitFor({ timeout: 30_000 });
      await page.locator(".cv-user__images img").first().waitFor({ timeout: 30_000 });
      expect(await page.locator(".cv-user__images img").first().getAttribute("src")).toStartWith("data:image/png");
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a file dropped on the New Tab page shows as a chip; a pasted image alone is a prompt",
    async (name) => {
      const page = await newTab(name);
      const data = await transfer(page, "Dropped.png");
      await page.locator(".nt-screen").evaluate((node, data) => {
        for (const type of ["dragenter", "dragover", "drop"])
          node.dispatchEvent(new DragEvent(type, { dataTransfer: data, bubbles: true, cancelable: true }));
      }, data);
      await page.locator(".nt-box .acpmux-attachment-image").waitFor();
      // Removing it is the chip's own ×, as in a chat.
      await page.locator(".nt-box .acpmux-attachment-remove").click();
      expect(await page.locator(".nt-box .acpmux-attachment").count()).toBe(0);
      // A pasted image and no text: Return starts the chat with the image.
      const field = page.locator(".nt-field");
      await field.click();
      const pasted = await transfer(page);
      await field.evaluate(
        (node, data) =>
          node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
        pasted,
      );
      await page.locator(".nt-box .acpmux-attachment-image").waitFor();
      await page.keyboard.press("Enter");
      await page.locator(".cv-user__images img").first().waitFor({ timeout: 30_000 });
      await page.close();
    },
  );

  // Austin 2026-10-21: a pasted image went only by its ×. Backspace with the caret at the field's
  // start takes back the last chip, one per press; Backspace in the text still edits the text.
  test.each(engines.map(([name]) => name))(
    "%s: Backspace at the field's start removes the last pasted image, one per press",
    async (name) => {
      const page = await newTab(name);
      const field = page.locator(".nt-field");
      await field.click();
      for (const file of ["One.png", "Two.png"]) {
        const data = await transfer(page, file);
        await field.evaluate(
          (node, data) =>
            node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
          data,
        );
      }
      const images = page.locator(".nt-box .acpmux-attachment-image");
      await images.nth(1).waitFor();
      await page.keyboard.type("ab");
      // A frame after each press, so a chip removed by mistake is gone before the count.
      const frame = () => page.evaluate(() => new Promise((done) => requestAnimationFrame(done)));
      await page.keyboard.press("Backspace");
      await frame();
      expect(await field.inputValue()).toBe("a");
      expect(await images.count()).toBe(2);
      await page.keyboard.press("Backspace");
      await frame();
      expect(await field.inputValue()).toBe("");
      expect(await images.count()).toBe(2);
      await page.keyboard.press("Backspace");
      await page.waitForFunction(() => document.querySelectorAll(".nt-box .acpmux-attachment-image").length === 1);
      await page.keyboard.press("Backspace");
      await page.waitForFunction(() => document.querySelectorAll(".nt-box .acpmux-attachment").length === 0);
      await page.close();
    },
  );

  // The Classic New Tab page takes Backspace the same way, after its own: a "!" typed into the empty
  // field switches it to a terminal, and Backspace first switches it back; the chips go after that.
  test.each(engines.map(([name]) => name))(
    "%s: on the Classic New Tab page, Backspace undoes a prefix first, then removes the last image",
    async (name) => {
      const page = await newTab(name, true);
      const field = page.locator("input.acpmux-newtab-field");
      await field.click();
      for (const file of ["One.png", "Two.png"]) {
        const data = await transfer(page, file);
        await field.evaluate(
          (node, data) =>
            node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
          data,
        );
      }
      const images = page.locator(".acpmux-newtab .acpmux-attachment-image");
      await images.nth(1).waitFor();
      const kind = () => page.locator(".acpmux-newtab").getAttribute("data-kind");
      expect(await kind()).toBe("agent");
      await page.keyboard.type("!");
      await page.waitForFunction(
        () => document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "terminal",
      );
      expect(await field.inputValue()).toBe("");
      // A frame after the press, so a chip removed by mistake is gone before the count.
      await page.keyboard.press("Backspace");
      await page.waitForFunction(() => document.querySelector(".acpmux-newtab")?.getAttribute("data-kind") === "agent");
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(done)));
      expect(await images.count()).toBe(2);
      await page.keyboard.press("Backspace");
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-newtab .acpmux-attachment-image").length === 1,
      );
      await page.keyboard.press("Backspace");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-newtab .acpmux-attachment").length === 0);
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: with an image staged, Return on an address asks a chat instead of opening the page",
    async (name) => {
      const page = await newTab(name);
      const field = page.locator(".nt-field");
      await field.click();
      await page.keyboard.type("example.com");
      const data = await transfer(page);
      await field.evaluate(
        (node, data) =>
          node.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true })),
        data,
      );
      await page.locator(".nt-box .acpmux-attachment-image").waitFor();
      await page.keyboard.press("Enter");
      await page.locator(".cv-user__bubble", { hasText: "example.com" }).waitFor({ timeout: 30_000 });
      await page.locator(".cv-user__images img").first().waitFor({ timeout: 30_000 });
      await page.close();
    },
  );
});
