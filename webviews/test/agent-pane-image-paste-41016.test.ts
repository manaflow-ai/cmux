// https://github.com/manaflow-ai/cmux/issues/41016: "pasting an image (Cmd+V) into the agent chat
// composer takes noticeably long before it appears. Separately, when an image first loads in the
// chat, its UUID text shows before the image renders."
//
// - A pasted Retina screenshot shows its tile at once and becomes its chip within a bounded time,
//   with the page's main thread never stalled for long on the way.
// - A prompt with a pasted image sent in a new chat waits as a queued row until the chat takes it
//   (startingSends.ts): that row shows its words and the picture, never the image's id. Before, it
//   drew the draft as it was: U+FFFC, the attachment's UUID, U+FFFC.
//
// The page is the pane's dev entry with the in-page mock host, which never takes a new chat's first
// prompt, so the prompt stays in that queued row. Real Chromium from Playwright; CI fails the file when
// it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-image-paste-41016.test.ts", async () => {
  /// From the paste to the loading tile: it is drawn in the paste's own task.
  const MAX_TILE_MS = 250;
  /// From the paste to the chip with its picture, for a 3456x2234 screenshot.
  const MAX_READY_MS = 2_500;
  /// The longest the main thread may stall meanwhile.
  const MAX_STALL_MS = 150;
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-image-paste-41016: skipping (run `bunx playwright install chromium`)");
    describe.skip("image paste", () => test("chromium", () => {}));
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
            agentSession: { postMessage: () => Promise.resolve({ ok: true, value: null }) },
          },
        },
        cmuxAcpmuxActions: { ready: async () => ({ protocolVersion: 1, transport: "mock", newSession: true }) },
      });
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    return page;
  }

  /// The DEBUG probe the app's `debug.agent_pane paste_probe` runs (pasteProbe.ts): it pastes a
  /// screenshot through the page's paste path and times it, and with `send` sends it and lists every
  /// UUID the page showed as text meanwhile.
  async function probe(page: Page, options: Record<string, unknown>): Promise<Record<string, unknown>> {
    type Debug = { cmuxAcpmuxDebug: { pasteProbe(o: unknown): Promise<Record<string, unknown>> } };
    await page.evaluate((options) => (window as unknown as Debug).cmuxAcpmuxDebug.pasteProbe(options), options);
    return page.evaluate(() => (window as unknown as Debug).cmuxAcpmuxDebug.pasteProbe({ wait: true }));
  }

  test("a pasted Retina screenshot shows its tile at once and its chip within its budget", async () => {
    const page = await newChat();
    const result = await probe(page, {});
    console.log(`pasted screenshot: ${JSON.stringify(result)}`);
    expect(result.error).toBeUndefined();
    expect(result.tile as number).toBeLessThan(MAX_TILE_MS);
    expect(result.ready as number).toBeLessThan(MAX_READY_MS);
    expect(result.stall as number).toBeLessThan(MAX_STALL_MS);
    await page.close();
  });

  test("a new chat's first prompt with a pasted image never shows the image's id", async () => {
    // The dev entry as it opens, its mock host with nothing in front of it: a new chat that has not
    // taken its first prompt yet.
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".acpmux-composer-prompt [contenteditable='true']").click();
    const pasted = await probe(page, {});
    expect(pasted.error).toBeUndefined();
    // Every frame from here on that shows a UUID as text, or an image still drawing its id as alt.
    await page.evaluate(() => {
      const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
      const seen = new Set<string>();
      Object.assign(window, { idsSeen: seen });
      const scan = () => {
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const parent = node.parentElement;
          if (!parent || !UUID.test(node.textContent ?? "") || parent.offsetParent === null) continue;
          if (parent.closest("script,style,[aria-hidden='true'],.visually-hidden")) continue;
          seen.add(`<${parent.tagName.toLowerCase()} class="${parent.className}">: ${node.textContent!.slice(0, 120)}`);
        }
        for (const image of document.querySelectorAll("img"))
          if (UUID.test(image.alt) && !(image.complete && image.naturalWidth)) seen.add(`img alt=${image.alt}`);
        // raf-read: the DOM's text in every frame, not its paint, is what is checked: a frame that
        // holds an id as text the person can see fails, however briefly it was there.
        requestAnimationFrame(scan);
      };
      requestAnimationFrame(scan);
    });
    // Sent as the person sends it: words after the picture, then Return.
    await page.keyboard.type(" look at this");
    await page.keyboard.press("Enter");
    // The waiting row draws the picture itself under its words.
    const row = page.locator(".acpmux-queued").first();
    await row.waitFor();
    // An id could only show until the row's picture has drawn: watched until then.
    await row
      .locator("img")
      .first()
      .evaluate((image: HTMLImageElement) => image.decode());
    await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const seen = await page.evaluate(() => [...(window as unknown as { idsSeen: Set<string> }).idsSeen]);
    expect(seen).toEqual([]);
    expect(await row.locator("img").count()).toBeGreaterThan(0);
    const words = await row.locator(".acpmux-queued-clamp").textContent();
    expect(words).toContain("look at this");
    expect(words).not.toContain("\uFFFC");
    await page.close();
  });
});
