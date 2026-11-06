// Leo, 2026-10-13: the images attached to a prompt vanished once it was sent. acpmux names a
// prompt's images in its user_message (`images: [{id, mimeType, name}]`) and reads one back with
// `_acpmux/attachment`; the sent bubble shows each as a thumbnail that opens the image viewer, and
// Edit sends the edited prompt with its images. The page is the pane's dev entry with the in-page
// mock transport, which keeps and names images as acpmux does.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-sent-images.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-sent-images: skipping (run `bunx playwright install chromium`)");
    describe.skip("sent images", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  async function newChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: { postMessage: async () => ({ ok: true, value: null }) },
          },
        },
        cmuxAcpmuxActions: {
          ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }),
        },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// A sent prompt's image thumbnail: in the band over the bubble, or at its place in the bubble's text
  /// (a prompt whose image the composer placed inline, the default view).
  const SENT_IMAGE = ".cv-user__images img, .cv-user__inline-image img";
  const SENT_IMAGE_BUTTON = ".cv-user__images button, .cv-user__inline-image button";

  /// Pastes a small PNG screenshot into the prompt.
  const pasteImage = (page: Page) =>
    page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 120;
      canvas.height = 80;
      const context = canvas.getContext("2d")!;
      context.fillStyle = "#3a7bd5";
      context.fillRect(0, 0, canvas.width, canvas.height);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      const target = document.querySelector('.acpmux-composer-prompt [contenteditable="true"]')!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });

  /// The sent prompts' bubbles: their text and how many image thumbnails each shows.
  const bubbles = (page: Page) =>
    page
      .locator(".cv-user")
      .evaluateAll(
        (rows, image) =>
          rows.map((row) => [
            row.querySelector(".cv-user__bubble")?.textContent?.trim(),
            row.querySelectorAll(image).length,
          ]),
        SENT_IMAGE,
      );

  test("a sent prompt keeps its images: thumbnails that open the viewer, and Edit sends them again", async () => {
    const page = await newChat();
    const prompt = page.locator('.acpmux-composer-prompt [contenteditable="true"]');
    // Edit forks through the turn before a prompt, so the image goes with the chat's second prompt.
    await prompt.click();
    await page.keyboard.type("hello");
    await page.keyboard.press("Enter");
    await page.locator(".cv-user__bubble", { hasText: "hello" }).waitFor();
    const stop = page.getByRole("button", { name: "Stop" });
    await stop.waitFor();
    await stop.waitFor({ state: "detached", timeout: 30_000 });
    await prompt.click();
    await pasteImage(page);
    await page.locator(".acpmux-attachment-image").waitFor();
    await page.keyboard.type("what is this");
    await page.keyboard.press("Enter");
    // The composer lets the image go; the bubble shows it.
    await page.locator(SENT_IMAGE).first().waitFor({ timeout: 10_000 });
    expect(await page.locator(".acpmux-attachment-image").count()).toBe(0);
    expect(await bubbles(page)).toEqual([
      ["hello", 0],
      ["what is this", 1],
    ]);
    expect(await page.locator(SENT_IMAGE).first().getAttribute("src")).toStartWith("data:image/png");

    await page.locator(SENT_IMAGE_BUTTON).first().click();
    await page.locator(".acpmux-image-viewer").waitFor();
    await page.keyboard.press("Escape");
    await page.locator(".acpmux-image-viewer").waitFor({ state: "detached" });

    // Once the turn ends, Edit opens the prompt; Send forks there with the edited text and the image.
    await page.locator(".cv-user").nth(1).hover();
    await page.getByRole("button", { name: "Edit", exact: true }).click({ timeout: 15_000 });
    const editor = page.getByRole("textbox", { name: "Edit your message" });
    await editor.fill("what is this, again");
    await page.locator(".cv-user__edit").getByRole("button", { name: "Send", exact: true }).click();
    await page.locator(".cv-user__bubble", { hasText: "what is this, again" }).waitFor({ timeout: 10_000 });
    await page.locator(SENT_IMAGE).first().waitFor({ timeout: 10_000 });
    expect(await bubbles(page)).toEqual([
      ["hello", 0],
      ["what is this, again", 1],
    ]);
    await page.close();
  });
});
