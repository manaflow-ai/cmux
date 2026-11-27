// A prompt that was not sent, in the real agent pane (hq#2569 item 5). The page is the pane's dev
// entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon that refuses session/prompt the way the app's relay does when no click or
// key of the person's own is behind it (`transport.gesture_required`), as it did for every send of
// the parity audit, which drove the pane with posted events.
//
// - The bubble says why it was not sent, beside the message, never a bare "Press Retry".
// - Retry (the bubble's button) sends the same prompt again; once acpmux takes it, the turn runs
//   and the failure goes.
// - A Retry refused again says "Still not sent", so the click visibly did something.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-not-sent-retry.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-not-sent-retry: skipping (run `bunx playwright install chromium`)");
    describe.skip("not sent", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d5";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/parity-demo",
    title: "Todo commands",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: Date.now(),
  };
  const update = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  let events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  let opened = 0;
  /// Every session/prompt the pane sent, by its text.
  let prompts: string[] = [];
  /// How many of the next session/prompts the relay refuses.
  let refusals = 0;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  /// The relay's refusal, or acpmux's run of the prompt: its row, the reply, its end.
  function prompt(ws: { send(data: string): void }, params: Record<string, any>, id: number) {
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    prompts.push(text);
    if (refusals > 0) {
      refusals -= 1;
      ws.send(
        JSON.stringify({
          jsonrpc: "2.0",
          id,
          error: {
            code: -32000,
            message: "transport.gesture_required",
            data: { code: "transport.gesture_required", origin: "native" },
          },
        }),
      );
      return;
    }
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    send(record("mux", "user_message", { text, promptId: params._meta?.acpmux?.promptId }));
    send(record("mux", "turn_started", {}));
    send(record("in", "agent_message_chunk", update("Added both commands.")));
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt" && message.id !== undefined)
            return prompt(ws, message.params ?? {}, message.id);
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The chat with one finished turn, and a prompt sent the way the New Tab page sends its ask
  /// (`chat.send` with no composer holding it), which the relay refuses `refused` times.
  async function sendRefused(refused: number): Promise<Page> {
    events = [];
    record("mux", "user_message", { text: "Read todo.py", promptId: "p-0" });
    record("mux", "turn_started", {});
    record("in", "agent_message_chunk", update("It has add, list and done."));
    record("mux", "turn_result", { status: "completed" });
    opened = events.length;
    prompts = [];
    refusals = refused;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // The file's first page loads the pane's modules cold; on a busy runner that took over 10 s.
    await page.getByText("It has add, list and done.").waitFor({ timeout: 60_000 });
    await page.waitForFunction(() => Boolean(window.cmuxAcpmuxActions?.["chat.retryPrompt"]));
    await page.evaluate(() => {
      void window.cmuxAcpmuxActions!["chat.send"]!({ text: "Add a remove command" })?.catch?.(() => undefined);
    });
    return page;
  }

  const failure = (page: Page) => page.locator(".cv-user__status--failed");

  describe("a prompt that was not sent", () => {
    test("says why beside its bubble, and Retry sends it again", async () => {
      const page = await sendRefused(1);
      await failure(page).waitFor({ timeout: 10_000 });
      expect(await failure(page).innerText()).toContain("Not sent: it needs your own key press or click.");
      expect(await page.locator("body").innerText()).not.toContain("Press Retry");
      await failure(page).getByRole("button", { name: "Retry" }).click();
      await page.getByText("Added both commands.").waitFor({ timeout: 10_000 });
      await failure(page).waitFor({ state: "detached", timeout: 10_000 });
      expect(prompts).toEqual(["Add a remove command", "Add a remove command"]);
      expect(await page.getByText("Add a remove command", { exact: true }).count()).toBe(1);
      await page.close();
    });

    test("a Retry refused again says it is still not sent", async () => {
      const page = await sendRefused(2);
      await failure(page).waitFor({ timeout: 10_000 });
      await failure(page).getByRole("button", { name: "Retry" }).click();
      await page.getByText("Still not sent: it needs your own key press or click.").waitFor({ timeout: 10_000 });
      expect(prompts).toEqual(["Add a remove command", "Add a remove command"]);
      expect(await page.getByText("Add a remove command", { exact: true }).count()).toBe(1);
      // It keeps its Retry.
      expect(await failure(page).getByRole("button", { name: "Retry" }).count()).toBe(1);
      await page.close();
    });
  });
});
