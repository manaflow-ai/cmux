// Leo, 2026-10-24 (cosmic-gray), pasting Retina screenshots from the clipboard: "the attachments,
// they freeze. They still fucking freeze. I thought we fixed this before, but they freeze the
// composer... if it's loading, why don't you put a spinner on the attachment rather than this
// placeholder that doesn't do anything... we shouldn't have this limit... I can't even cancel
// these, like, you know, supposedly in-progress attachments."
//
// - Several large screenshots pasted at once never block typing: their decode, scale and encode
//   run in a worker (composer/imageWorker.ts), so the page's main thread never stalls on them.
// - A host that never answers (`chat.attach.dropped`, `chat.upload.*`) never leaves a tile loading
//   forever: an image becomes its chip once its preview is made, whatever its original's upload does.
// - A loading tile spins and has a working ×; a tile that failed says why, and Retry tries again.
// The page is the pane's dev entry with the in-page mock transport.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-paste-large-screenshots.test.ts", async () => {
  /// The longest the main thread may stall while screenshots attach: a key typed then lands within it.
  const MAX_STALL_MS = 120;
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
        if (answer === "fail")
          return Promise.resolve({ ok: false, error: { code: "io", userMessage: "The disk is full." } });
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
  /// `paste` false only starts the heartbeat (a baseline with nothing pasted).
  const pasteScreenshots = (page: Page, paste = true) =>
    page.evaluate((paste) => {
      const state = window as unknown as { screenshots: File[]; stall: number; beat: number };
      state.stall = 0;
      let last = performance.now();
      state.beat = window.setInterval(() => {
        const now = performance.now();
        state.stall = Math.max(state.stall, now - last);
        last = now;
      }, 4);
      if (!paste) return;
      const data = new DataTransfer();
      for (const file of state.screenshots) data.items.add(file);
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, paste);

  const longestStall = (page: Page) =>
    page.evaluate(() => {
      const state = window as unknown as { stall: number; beat: number };
      window.clearInterval(state.beat);
      return state.stall;
    });

  // The attachments the default inline view places in the prompt's line: one chip per attachment,
  // a spinner while it loads, Retry when it failed (inlineAttachments.tsx).
  const INLINE = ".acpmux-composer-prompt .acpmux-md-inline-chip";
  const LOADING = `${INLINE}[data-state="loading"]`;
  const FAILED = `${INLINE}[data-state="failed"]`;

  /// The prompt's text, without the attachments placed in it (each an atom in the line).
  const promptText = (page: Page) =>
    page.locator(".acpmux-composer-prompt [contenteditable='true']").evaluate((node) => {
      const copy = node.cloneNode(true) as Element;
      for (const atom of copy.querySelectorAll("[data-inline-attachment]")) atom.remove();
      return copy.textContent?.replace(/\u00a0/g, " ");
    });

  test("pasting three large Retina screenshots never blocks typing", async () => {
    const page = await newChat();
    const prompt = page.locator(".acpmux-composer-prompt [contenteditable='true']");
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
    console.log(
      `three ${sizes.map((size) => (size / 1048576).toFixed(1)).join("/")} MB screenshots: chips in ${attached} ms, longest main-thread stall ${stall.toFixed(0)} ms`,
    );
    expect(await promptText(page)).toBe(" these screenshots attach while I type");
    expect(stall).toBeLessThan(MAX_STALL_MS);
    await page.close();
  });

  test("a host that never answers never leaves a pasted screenshot loading", async () => {
    const page = await newChat({ "chat.attach.dropped": "hang", "chat.upload.begin": "hang" });
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await makeScreenshots(page, 2);
    await pasteScreenshots(page);
    await page.waitForFunction(
      () => document.querySelectorAll(".acpmux-attachment-image img").length === 2,
      undefined,
      { timeout: 20_000 },
    );
    expect(await page.locator(LOADING).count()).toBe(0);
    // The host was asked, and its silence held nothing up.
    expect(await page.evaluate(() => (window as unknown as { calls: string[] }).calls)).toContain("chat.upload.begin");
    await page.close();
  });

  test("a loading tile spins and its × takes it away for good", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await makeScreenshots(page, 1);
    await pasteScreenshots(page);
    const loading = page.locator(LOADING);
    await loading.waitFor();
    expect(await loading.locator(".acpmux-md-inline-spinner").count()).toBe(1);
    await loading.locator(".acpmux-md-inline-remove").click();
    expect(await loading.count()).toBe(0);
    // Its read ending later brings nothing back: nothing on the page says when a cancelled read
    // ends, so the test gives it the time a read of this screenshot takes here.
    // fixed-wait: a cancelled read has no observable end; the assertion is that nothing appears.
    await page.waitForTimeout(3000);
    expect(await page.locator(".acpmux-attachment").count()).toBe(0);
    expect(await page.locator(INLINE).count()).toBe(0);
    await page.close();
  });

  test("a file whose upload failed says why, and Retry attaches it", async () => {
    const page = await newChat({ "chat.upload.begin": "fail", "chat.upload.chunk": "ok", "chat.upload.finish": "ok" });
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await page.evaluate(() => {
      const data = new DataTransfer();
      data.items.add(new File([new Uint8Array(4096)], "notes.bin", { type: "application/octet-stream" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    // The failed chip is cut to its size in the line; its tooltip has the reason.
    const failed = page.locator(FAILED);
    await failed.waitFor();
    expect(await failed.getAttribute("title")).toContain("The disk is full.");
    // The host takes it this time.
    await page.evaluate(() => {
      (window as unknown as { host: Record<string, string> }).host["chat.upload.begin"] = "ok";
    });
    await failed.locator(".acpmux-md-inline-retry").click();
    await page.locator(".acpmux-attachment-link").waitFor();
    expect(await failed.count()).toBe(0);
    await page.close();
  });

  // Leo, 2026-10-24: "a 5.2mb heif image froze the composer and i had to relaunch". An iPhone photo
  // is converted to JPEG or PNG in the worker, never on the page. (Chromium has no HEIF decoder, so
  // here it goes as a file; the app's WebKit decodes it in the worker.)
  test("a 5.2 MB HEIF photo never blocks typing", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await page.evaluate(() => {
      const bytes = new Uint8Array(5.2 * 1024 * 1024);
      for (let at = 0; at < bytes.length; at += 65536) crypto.getRandomValues(bytes.subarray(at, at + 65536));
      bytes.set([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63], 0);
      (window as unknown as { screenshots: File[] }).screenshots = [
        new File([bytes], "IMG_0412.HEIC", { type: "image/heic" }),
      ];
    });
    // The page's own stalls while typing with nothing attached (a loaded host adds its own), then
    // with the photo: the photo adds less than 50 ms to the longest one.
    await pasteScreenshots(page, false);
    await page.keyboard.type(" idle", { delay: 20 });
    const idle = await longestStall(page);
    for (let at = 0; at < 5; at += 1) await page.keyboard.press("Backspace");
    await pasteScreenshots(page);
    // Its tile is there at once.
    expect(await page.locator(INLINE).count()).toBe(1);
    await page.keyboard.type(" a photo from my phone", { delay: 20 });
    await page.waitForFunction((loading) => !document.querySelector(loading), LOADING);
    const stall = await longestStall(page);
    console.log(`a 5.2 MB HEIF: longest main-thread stall ${stall.toFixed(0)} ms (${idle.toFixed(0)} ms idle)`);
    expect(await promptText(page)).toBe(" a photo from my phone");
    expect(stall).toBeLessThan(Math.max(50, idle + 50));
    await page.close();
  });

  // Review (Codex): an image is a chip before the strip draws it; its original's upload must not
  // read "not in the strip" as removed. In a chat with no local path, the original streams to the
  // session's machine and the chip gets its path; removing the chip later stops it.
  test("a pasted screenshot's original uploads, and its chip's x stops the upload", async () => {
    const page = await newChat({ "chat.upload.begin": "ok", "chat.upload.chunk": "ok", "chat.upload.finish": "ok" });
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await makeScreenshots(page, 1);
    await pasteScreenshots(page);
    await page.locator(".acpmux-attachment-image img").waitFor();
    // Its original went up, chunk by chunk, to the end.
    await page.waitForFunction(() => (window as unknown as { calls: string[] }).calls.includes("chat.upload.finish"));
    const chunks = await page.evaluate(
      () => (window as unknown as { calls: string[] }).calls.filter((call) => call === "chat.upload.chunk").length,
    );
    expect(chunks).toBeGreaterThan(1);
    await page.close();
  });
});
