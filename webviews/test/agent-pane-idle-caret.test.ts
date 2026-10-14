// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reply's live edge (the block caret, `.cv-caret`) shows only while that reply is still being
// written (Leo 2026-10-13, cmux NEXT). Once the chat is idle no reply keeps it, and a reply the
// agent moved on from (a newer message started below it) loses it at once.
//
// Before: text that arrived after the turn's result (a late reply, a background task's report)
// opened a streaming row that nothing ever closed, and a reply followed by a newer message kept
// streaming: the caret blinked at the end of it for good.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-idle-caret.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-idle-caret: skipping (run `bunx playwright install chromium`)");
    describe.skip("idle caret", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LATE = "0190a000-0000-7000-8000-0000000000f4";
  const MOVED_ON = "0190a000-0000-7000-8000-0000000000f5";
  const START = Date.UTC(2026, 9, 13, 19, 0, 0);
  const say = (text: string, messageId?: string) => ({
    method: "session/update",
    params: {
      sessionId: "agent-1",
      update: {
        sessionUpdate: "agent_message_chunk",
        ...(messageId ? { messageId } : {}),
        content: { type: "text", text },
      },
    },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const chats: Record<string, { title: string; status: string; steps: Step[] }> = {
    // The turn ended, then the agent wrote again with no turn around it; the chat is idle.
    [LATE]: {
      title: "Late reply",
      status: "idle",
      steps: [
        ["mux", "user_message", { text: "Who owns the chat column PR?", promptId: "p-1" }],
        ["mux", "turn_started", {}],
        ["in", "agent_message_chunk", say("Checking the lanes.")],
        ["mux", "turn_result", { status: "completed" }],
        ["in", "agent_message_chunk", say("The chat column PR: not touching it.")],
      ],
    },
    // Still working: the first message ended when the second began.
    [MOVED_ON]: {
      title: "Moved on",
      status: "running",
      steps: [
        ["mux", "user_message", { text: "Summarize the queue.", promptId: "p-1" }],
        ["mux", "turn_started", {}],
        ["in", "agent_message_chunk", say("First I read the queue file.", "m-1")],
        ["in", "agent_message_chunk", say("Now the summary is coming", "m-2")],
      ],
    },
  };
  const session = (id: string) => ({
    sessionId: id,
    cwd: "/home/dev/cmux",
    title: chats[id]!.title,
    harness: "claude",
    family: "claude",
    status: chats[id]!.status,
    turnCount: 1,
    updatedAt: START,
  });
  const events = (id: string) =>
    chats[id]!.steps.map(([dir, kind, msg], index) => ({
      sessionId: id,
      seq: index + 1,
      at: START + index * 9000,
      dir,
      kind,
      msg,
    }));
  function answer(method: string, params: { sessionId?: string } | undefined): unknown {
    const id = params?.sessionId ?? LATE;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(LATE), session(MOVED_ON)] };
      case "_acpmux/attach":
        return { session: session(id), lastSeq: events(id).length, events: events(id) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events(id).length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (chat: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat}`;
  };
  const open = async (chat: string, text: string): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(chat));
    await page.getByText(text).waitFor();
    await page.waitForTimeout(400);
    return page;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { sessionId?: string } };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(LATE));
        await warm.getByText("not touching it").waitFor({ timeout: 25_000 });
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

  /// The replies that draw a caret, by their text.
  const withCaret = (page: Page) =>
    page
      .locator(".cv-md")
      .evaluateAll((nodes) =>
        nodes.filter((node) => node.querySelector(".cv-caret")).map((node) => node.textContent?.trim()),
      );

  test("an idle chat draws no caret, even after a reply that came after the turn ended", async () => {
    const page = await open(LATE, "not touching it");
    expect(await withCaret(page)).toEqual([]);
    await page.close();
  });

  test("a reply the agent moved on from loses its caret; only the one being written keeps it", async () => {
    const page = await open(MOVED_ON, "Now the summary is coming");
    expect(await withCaret(page)).toEqual(["Now the summary is coming"]);
    await page.close();
  });
});
