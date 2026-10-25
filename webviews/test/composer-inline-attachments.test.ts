// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-10-25: "the actual input, as a default, I don't think it's gonna be worse to put the
// things inline, like how iMessage on Mac does it" and "ALSO show the top displayed attachments
// alongside the inline attachments ... just so you can see it all and close aka delete". A pasted
// image goes into the prompt's text at the caret (composer/inlineNode.ts) and into the strip above
// it, as one attachment by id (composer/inlineAttachments.tsx):
// - typing goes on around it, and the prompt goes to the agent in the text's order;
// - a × in the strip takes it out of the text, Backspace in the text takes it out of the strip, and
//   undo brings it back to both;
// - moving it in the strip moves it in the text;
// - the prompt's right-click turns inline placement off: a paste then goes to the strip only.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-inline-attachments.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-inline-attachments: skipping (run `bunx playwright install chromium`)");
    describe.skip("inline attachments", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f4";
  const START = Date.UTC(2026, 9, 25, 9, 0, 0);
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Look at the build" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Send me screenshots." } },
        },
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "Build",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    promptCapabilities: { image: true },
  };
  const prompts: { type: string; text?: string; name?: string }[][] = [];
  let prompted = () => {};

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { prompt?: unknown } };
          if (message.method === "session/prompt") {
            prompts.push(message.params?.prompt as (typeof prompts)[number]);
            prompted();
          }
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Send me screenshots.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 1100, height: 720 } });
    await page.goto(url());
    await page.getByText("Send me screenshots.").waitFor();
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").click();
    return page;
  }

  /// Pastes one PNG `width` px wide, named for its width, as a ⌘V of a copied image.
  async function paste(page: Page, width: number) {
    const before = await page.locator(".acpmux-attachment-image img").count();
    await page.evaluate(async (width) => {
      const canvas = document.createElement("canvas");
      canvas.width = width;
      canvas.height = 200;
      const context = canvas.getContext("2d")!;
      context.fillStyle = `hsl(${width}, 60%, 50%)`;
      context.fillRect(0, 0, width, 200);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], `Shot ${width}.png`, { type: "image/png" }));
      const target = document.querySelector(".acpmux-composer-prompt [contenteditable=true]")!;
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, width);
    await page.waitForFunction(
      (count) => document.querySelectorAll(".acpmux-attachment-image img").length === count,
      before + 1,
    );
  }

  /// The images' widths in the text's order, and in the strip's.
  const widths = (page: Page, selector: string) =>
    page.evaluate(
      (selector) =>
        [...document.querySelectorAll<HTMLImageElement>(selector)].map(
          (img) => /Shot (\d+)/.exec(img.alt)?.[1] ?? img.alt,
        ),
      selector,
    );
  const inText = (page: Page) => widths(page, ".acpmux-md .acpmux-md-inline img");
  const inStrip = (page: Page) => widths(page, ".acpmux-attachment-image img");

  test("an image pasted mid-sentence goes in at the caret, the strip lists it, and the prompt goes in the text's order", async () => {
    const page = await open();
    await page.keyboard.type("look at ");
    await paste(page, 300);
    await page.keyboard.type(" and ");
    await paste(page, 400);
    await page.keyboard.type(" ok");
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-md .acpmux-md-inline img").length === 2);
    expect(await inText(page)).toEqual(["300", "400"]);
    expect(await inStrip(page)).toEqual(["300", "400"]);
    // Typing went on around them: the text reads in order with the images where they were pasted.
    expect(
      await page
        .locator(".acpmux-composer-prompt .ProseMirror p")
        .evaluate((paragraph) =>
          [...paragraph.childNodes]
            .map((node) =>
              node instanceof HTMLElement && node.classList.contains("acpmux-md-inline") ? "[img]" : node.textContent,
            )
            .join(""),
        ),
    ).toBe("look at [img] and [img] ok");
    prompts.length = 0;
    const sent = new Promise<void>((resolve) => (prompted = resolve));
    await page.keyboard.press("Enter");
    await sent;
    expect(prompts[0]!.map((block) => block.type)).toEqual(["text", "image", "text", "image", "text"]);
    expect(prompts[0]!.filter((block) => block.type === "text").map((block) => block.text)).toEqual([
      "look at ",
      " and ",
      " ok",
    ]);
    expect(prompts[0]!.filter((block) => block.type === "image").map((block) => block.name)).toEqual([
      "Shot 300.png",
      "Shot 400.png",
    ]);
    // The composer is empty after it goes, both places.
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-attachment-image").length === 0);
    expect(await page.locator(".acpmux-md .acpmux-md-inline").count()).toBe(0);
    await page.close();
  });

  test("removing from either place removes from both, and undo brings it back to both", async () => {
    const page = await open();
    await page.keyboard.type("one ");
    await paste(page, 300);
    await page.keyboard.type(" two ");
    await paste(page, 400);
    // The strip's × on the first.
    await page.locator(".acpmux-attachment-image").first().hover();
    await page.getByRole("button", { name: "Remove Shot 300.png" }).first().click();
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-md .acpmux-md-inline").length === 1);
    expect(await inText(page)).toEqual(["400"]);
    expect(await inStrip(page)).toEqual(["400"]);
    // Backspace in the text right after the second.
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").press("End");
    await page.keyboard.press("Backspace");
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-attachment-image").length === 0);
    expect(await inText(page)).toEqual([]);
    // Undo puts it back in the text and in the strip.
    await page.keyboard.press("ControlOrMeta+z");
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-attachment-image img").length === 1);
    expect(await inText(page)).toEqual(["400"]);
    expect(await inStrip(page)).toEqual(["400"]);
    await page.close();
  });

  test("moving an attachment in the strip moves it in the text", async () => {
    const page = await open();
    await page.keyboard.type("first ");
    await paste(page, 300);
    await page.keyboard.type(" then ");
    await paste(page, 400);
    await page.locator(".acpmux-attachment-image .acpmux-attachment-open").first().focus();
    await page.keyboard.press("Alt+ArrowRight");
    expect(await inStrip(page)).toEqual(["400", "300"]);
    await page.waitForFunction(() =>
      [...document.querySelectorAll<HTMLImageElement>(".acpmux-md .acpmux-md-inline img")][0]?.alt.includes("400"),
    );
    expect(await inText(page)).toEqual(["400", "300"]);
    expect(
      await page.locator(".acpmux-composer-prompt .ProseMirror p").evaluate((paragraph) => paragraph.textContent),
    ).toBe("first  then ");
    await page.close();
  });

  test("a copy of the prompt's text pasted in it brings a copy of its attachment", async () => {
    const page = await open();
    await page.keyboard.type("before ");
    await paste(page, 300);
    await page.evaluate(() => {
      const editable = document.querySelector<HTMLElement>(".acpmux-composer-prompt [contenteditable=true]")!;
      const field = (document.querySelector(".acpmux-md-field") as HTMLElement & {
        acpmuxMarkdownField?: { selectAll(): void; setCaret(offset: number): void };
      }).acpmuxMarkdownField!;
      const data = new DataTransfer();
      field.selectAll();
      editable.dispatchEvent(new ClipboardEvent("copy", { clipboardData: data, bubbles: true, cancelable: true }));
      field.setCaret(10_000);
      editable.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-attachment-image img").length === 2);
    expect(await inText(page)).toEqual(["300", "300"]);
    expect(await inStrip(page)).toEqual(["300", "300"]);
    // Each is its own: the copy's × leaves the original.
    await page.locator(".acpmux-attachment-image").nth(1).hover();
    await page.getByRole("button", { name: "Remove Shot 300.png" }).nth(1).click();
    await page.waitForFunction(() => document.querySelectorAll(".acpmux-md .acpmux-md-inline img").length === 1);
    expect(await inStrip(page)).toEqual(["300"]);
    await page.close();
  });

  test("the prompt's right-click turns inline placement off: a paste goes to the strip only", async () => {
    const page = await open();
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").click({ button: "right" });
    await page.getByRole("menuitem", { name: "Keep Attachments Above the Prompt" }).click();
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").click();
    await page.keyboard.type("strip only ");
    await paste(page, 300);
    expect(await inStrip(page)).toEqual(["300"]);
    expect(await page.locator(".acpmux-md .acpmux-md-inline").count()).toBe(0);
    // And back on, for the next paste.
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").click({ button: "right" });
    await page.getByRole("menuitem", { name: "Place Attachments in the Text" }).click();
    await page.locator(".acpmux-composer-prompt [contenteditable=true]").click();
    await paste(page, 400);
    expect(await inText(page)).toEqual(["400"]);
    expect(await inStrip(page)).toEqual(["300", "400"]);
    await page.close();
  });
});
