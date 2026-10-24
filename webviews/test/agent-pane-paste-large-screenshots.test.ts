// Leo, 2026-10-24 (cosmic-gray), pasting Retina screenshots from the clipboard: "the attachments,
// they freeze. They still fucking freeze. I thought we fixed this before, but they freeze the
// composer... if it's loading, why don't you put a spinner on the attachment rather than this
// placeholder that doesn't do anything... we shouldn't have this limit... I can't even cancel
// these, like, you know, supposedly in-progress attachments."
//
// - Several large screenshots pasted at once never block typing: their decode, scale and encode
//   run in a worker (composer/imageWorker.ts), so the page's main thread never stalls on them.
// The page is the pane's dev entry with the in-page mock transport.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

/// The longest the main thread may stall while screenshots attach: a key typed then lands within it.
const MAX_STALL_MS = 120;

await requireBrowserLane("agent-pane-paste-large-screenshots.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-paste-large-screenshots: skipping (run `bunx playwright install chromium`)");
    describe.skip("pasting large screenshots", () => test("chromium", () => {}));
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

  /// A chat whose host answers each native method in `host` (`"hang"`: never answers).
  async function newChat(host: Record<string, "hang" | "fail" | "ok"> = {}): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript((host) => {
      const state = window as unknown as { calls: string[]; host: Record<string, string> };
      state.calls = [];
      state.host = host;
      const reply = (method: string, params: Record<string, unknown>) => {
        const answer = state.host[method];
        if (!answer) return Promise.resolve({ ok: true, value: null });
        state.calls.push(method);
        if (answer === "hang") return new Promise(() => {});
        if (answer === "fail") return Promise.resolve({ ok: false, error: { code: "io", userMessage: "The disk is full." } });
        const value =
          method === "chat.upload.begin"
            ? { token: "t", size: params.size, chunkSize: 512 * 1024 }
            : method === "chat.upload.chunk"
              ? { offset: (params.offset as number) + atob(params.data as string).length }
              : method === "chat.upload.finish"
                ? { path: "/tmp/uploads/notes.bin" }
                : null;
        return Promise.resolve({ ok: true, value });
      };
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            agentSession: {
              postMessage: (message: { method: string; params: Record<string, unknown> }) =>
                reply(message.method, message.params),
            },
          },
        },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    }, host);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    return page;
  }

  /// Makes `count` Retina-sized screenshots (3456x2234, a few MB of PNG each, as ⌘⇧4 on a MacBook
  /// Pro makes) and keeps them on the page, before anything is timed.
  const makeScreenshots = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      const files: File[] = [];
      for (let index = 0; index < count; index += 1) {
        const canvas = document.createElement("canvas");
        canvas.width = 3456;
        canvas.height = 2234;
        const context = canvas.getContext("2d")!;
        const gradient = context.createLinearGradient(0, 0, canvas.width, canvas.height);
        gradient.addColorStop(0, "#1b1d24");
        gradient.addColorStop(1, `hsl(${index * 90}, 40%, 40%)`);
        context.fillStyle = gradient;
        context.fillRect(0, 0, canvas.width, canvas.height);
        // Text-like noise over part of it, so the PNG is several megabytes as a real one is.
        const noise = context.getImageData(0, 0, canvas.width, 900);
        for (let at = 0; at < noise.data.length; at += 4) {
          const value = (Math.random() * 255) | 0;
          noise.data[at] = noise.data[at + 1] = noise.data[at + 2] = value;
          noise.data[at + 3] = 255;
        }
        context.putImageData(noise, 0, 600);
        const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
        files.push(new File([blob], `Screenshot ${index + 1}.png`, { type: "image/png" }));
      }
      (window as unknown as { screenshots: File[] }).screenshots = files;
      return files.map((file) => file.size);
    }, count);

  /// Pastes the screenshots made by `makeScreenshots` into the prompt, as ⌘V does, and starts a
  /// heartbeat that records the main thread's longest stall from then on.
  const pasteScreenshots = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { screenshots: File[]; stall: number; beat: number };
      state.stall = 0;
      let last = performance.now();
      state.beat = window.setInterval(() => {
        const now = performance.now();
        state.stall = Math.max(state.stall, now - last);
        last = now;
      }, 4);
      const data = new DataTransfer();
      for (const file of state.screenshots) data.items.add(file);
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable]")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });

  const longestStall = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { stall: number; beat: number };
      window.clearInterval(state.beat);
      return state.stall;
    });

  const promptText = (page: Page) =>
    page
      .locator(".acpmux-composer-prompt [contenteditable]")
      .evaluate((node) => node.textContent?.replace(/ /g, " "));

  test("pasting three large Retina screenshots never blocks typing", async () => {
    const page = await newChat();
    const prompt = page.locator(".acpmux-composer-prompt [contenteditable]");
    await prompt.click();
    const sizes = await makeScreenshots(page, 3);
    expect(Math.min(...sizes)).toBeGreaterThan(2 * 1024 * 1024);
    const started = Date.now();
    await pasteScreenshots(page);
    await page.keyboard.type(" these screenshots attach while I type", { delay: 20 });
    await page.waitForFunction(() => {
      const images = [...document.querySelectorAll<HTMLImageElement>(".acpmux-attachment-image img")];
      return images.length === 3 && images.every((img) => img.complete && img.naturalWidth > 0);
    });
    const attached = Date.now() - started;
    const stall = await longestStall(page);
    console.log(`three ${sizes.map((size) => (size / 1048576).toFixed(1)).join("/")} MB screenshots: chips in ${attached} ms, longest main-thread stall ${stall.toFixed(0)} ms`);
    expect(await promptText(page)).toBe(" these screenshots attach while I type");
    expect(stall).toBeLessThan(MAX_STALL_MS);
    await page.close();
  });
});
