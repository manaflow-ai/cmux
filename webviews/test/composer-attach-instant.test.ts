// Leo, 2026-11-07, on a pasted screenshot's chip in a chat on this Mac with a retry arrow over its
// thumbnail: "do we EVER block them? we dont need to right? since they're local chats anyways? idk
// why we even show the retry symbol then (do we even retry? i mean it's just going to the path
// right? hell can't we make this all "appear" a lot faster if shit's just file paths at a certain
// point?"
//
// - A pasted image shows its picture at once, from the file itself (an object URL), while its
//   preview is still being made: never a blank spinner tile until the scale and base64 step ends.
// - In a chat on this Mac, an image's original that could not be saved beside it never puts a
//   retry arrow over its thumbnail: its preview sends as it is, and the save tries again on the
//   person's next key or click without a word.
//
// The page is the pane's dev entry with the in-page mock transport, a chat on this Mac whose host
// answers nothing (so `chat.upload.begin` starts no upload: the original's save fails).
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-attach-instant.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-attach-instant: skipping (run `bunx playwright install chromium`)");
    describe.skip("instant attachments", () => test("chromium", () => {}));
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
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await page.addInitScript(() => {
      Object.assign(window, {
        webkit: {
          messageHandlers: {
            // Counts the host's answers to `chat.upload.begin` (null: no upload starts).
            agentSession: {
              postMessage: async (message: unknown) => {
                if (JSON.stringify(message ?? null).includes("chat.upload.begin")) {
                  const counted = window as unknown as { uploadBegins?: number };
                  counted.uploadBegins = (counted.uploadBegins ?? 0) + 1;
                }
                return { ok: true, value: null };
              },
            },
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

  /// Pastes one large noisy screenshot (heavy to decode and scale) and answers how long, from the
  /// paste, until a picture first showed in the prompt (an `img` drawn with pixels), and whether its
  /// chip was still loading then.
  const pasteAndTime = (page: Page) =>
    page.evaluate(async () => {
      const canvas = document.createElement("canvas");
      canvas.width = 3600;
      canvas.height = 2400;
      const context = canvas.getContext("2d")!;
      const pixels = context.createImageData(canvas.width, canvas.height);
      let seed = 7;
      for (let index = 0; index < pixels.data.length; index += 4) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        pixels.data[index] = seed & 255;
        pixels.data[index + 1] = (seed >> 8) & 255;
        pixels.data[index + 2] = (seed >> 16) & 255;
        pixels.data[index + 3] = 255;
      }
      context.putImageData(pixels, 0, 0);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "Screenshot.png", { type: "image/png" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable='true']")!;
      const prompt = target.closest(".acpmux-composer-prompt")!;
      const seen = new Promise<{ ms: number; whileLoading: boolean }>((resolve) => {
        const started = performance.now();
        const look = () => {
          for (const img of prompt.querySelectorAll<HTMLImageElement>("img")) {
            if (!img.complete || img.naturalWidth === 0) continue;
            const chip = img.closest(".acpmux-md-inline-chip");
            return resolve({
              ms: performance.now() - started,
              whileLoading: chip?.getAttribute("data-state") === "loading",
            });
          }
          // raf-read: the measurement is the first frame a picture shows in, so it samples each one.
          requestAnimationFrame(look);
        };
        // raf-read: the same sampling, from the paste's frame.
        requestAnimationFrame(look);
      });
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
      return seen;
    });

  test("a pasted image shows its picture at once, before its preview is made", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    const runs: number[] = [];
    let whileLoading = true;
    for (let run = 0; run < 5; run += 1) {
      const seen = await pasteAndTime(page);
      runs.push(seen.ms);
      whileLoading &&= seen.whileLoading;
    }
    const sorted = [...runs].sort((a, b) => a - b);
    // The harness's number for the PR's Performance table: paste to first visible picture.
    console.log(
      `composer-attach-instant: paste to visible thumbnail ms p50=${sorted[2]!.toFixed(1)} max=${sorted[4]!.toFixed(1)} runs=${runs.map((ms) => ms.toFixed(1)).join(",")}`,
    );
    expect(whileLoading).toBe(true);
    await page.close();
  });

  test("a chat on this Mac never puts a retry arrow over a pasted image whose original was not saved", async () => {
    const page = await newChat();
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    await pasteAndTime(page);
    await page.locator(".acpmux-md-inline-chip[data-state='ready'] .acpmux-attachment-image img").first().waitFor();
    // The original's save was asked for and refused (the mock host starts no upload), and its
    // answer has painted.
    await page.waitForFunction(() => ((window as unknown as { uploadBegins?: number }).uploadBegins ?? 0) > 0);
    await page.evaluate(
      () => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0)))),
    );
    expect(await page.locator(".acpmux-attachment-original-retry").count()).toBe(0);
    expect(await page.locator(".acpmux-attachment-retry").count()).toBe(0);
    await page.close();
  });
});
