// l10n-allow-file: test fixture prompts, replies and model names, not shipped UI.
// The model the person picks sticks (cx-ncc.109, Codex desktop parity): after a send, the chat
// never goes back to the agent's default. Two paths: a pick on the New Tab page's model chip,
// then Return, which starts the chat; and a pick in a chat while its turn runs, then a send. In
// both the agent reports its own default first (the stand-in acpmux echoes what it runs), and the
// chat's chip and the model its next prompt runs on stay the pick. The page is the pane's dev
// entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-model-sticks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-model-sticks: skipping (run `bunx playwright install chromium`)");
    describe.skip("model sticks", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 15, 9, 0, 0);
  const CWD = "/home/dev/uploader";
  /// The agent's own default, and the model the person picks.
  const DEFAULT = "claude-opus-5-5";
  const PICK = "claude-sonnet-5-5";
  const model = (id: string, shortName: string) => ({ id, name: `Claude ${shortName}`, shortName });
  const claudeModels = [
    model("claude-opus-5-5", "Opus 5.5"),
    model("claude-sonnet-5-5", "Sonnet 5.5"),
    model("claude-haiku-5-5", "Haiku 5.5"),
  ];
  const harnesses = {
    harnesses: { claude: { kind: "claude-stdio", description: "found on PATH", family: "claude" } },
    families: { claude: ["claude"] },
    defaultHarness: "claude",
  };
  const models = { harnesses: [{ harness: "claude", kind: "claude-stdio", isDefault: true, models: claudeModels }] };

  type Session = Record<string, any> & { sessionId: string; model: string };
  type Chat = { session: Session; events: Record<string, unknown>[] };
  const chats = new Map<string, Chat>();
  const calls: { method: string; params: Record<string, any> }[] = [];
  const sockets = new Set<Bun.ServerWebSocket<unknown>>();
  let started = 0;
  /// The chat a running turn holds open, and the prompt that ends it once the test lets it.
  let holding: { sessionId: string; finish: () => void } | undefined;

  const broadcast = (method: string, params: unknown) => {
    const text = JSON.stringify({ jsonrpc: "2.0", method, params });
    for (const socket of sockets) socket.send(text);
  };
  /// acpmux tells every watcher the chat's summary, with the model it runs now.
  const changed = (chat: Chat, kind: string) =>
    broadcast("_acpmux/session_changed", { sessionId: chat.session.sessionId, session: chat.session, kind });
  const record = (chat: Chat, kind: string, msg: Record<string, unknown>) => {
    const event = {
      sessionId: chat.session.sessionId,
      seq: chat.events.length + 1,
      at: START + chat.events.length * 1000,
      dir: kind === "agent_message_chunk" ? "in" : "mux",
      kind,
      msg,
    };
    chat.events.push(event);
    broadcast("_acpmux/event", event);
  };
  const reply = (chat: Chat, text: string) =>
    record(chat, "agent_message_chunk", {
      method: "session/update",
      params: {
        sessionId: "agent-1",
        update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
      },
    });
  const summary = (sessionId: string, extra: Record<string, unknown> = {}): Session => ({
    sessionId,
    cwd: CWD,
    title: "",
    harness: "claude",
    family: "claude",
    model: DEFAULT,
    status: "idle",
    turnCount: 0,
    updatedAt: START,
    ...extra,
  });

  /// One prompt's turn: the agent spawns and reports what it runs (the model acpmux has for the
  /// chat, its default unless a pick reached acpmux first), answers, and ends the turn.
  function prompted(params: Record<string, any>, hold: boolean) {
    const chat = chats.get(String(params.sessionId))!;
    const meta = params._meta?.acpmux ?? {};
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    record(chat, "user_message", { text, promptId: meta.promptId, turnId: `turn-${meta.promptId}` });
    record(chat, "turn_started", { prompt: text, promptId: meta.promptId, turnId: `turn-${meta.promptId}` });
    chat.session = { ...chat.session, status: "running" };
    changed(chat, "config");
    const finish = () => {
      reply(chat, `Answered on ${chat.session.model}.`);
      record(chat, "turn_result", { status: "completed" });
      chat.session = { ...chat.session, status: "idle", turnCount: chat.session.turnCount + 1, title: text };
      changed(chat, "status");
    };
    if (hold) holding = { sessionId: chat.session.sessionId, finish };
    else setTimeout(finish, 150);
  }

  /// The answer to one request; `undefined` answers later (a prompt answers when its turn ends).
  function answer(method: string, params: Record<string, any>): unknown {
    calls.push({ method, params });
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [...chats.values()].map((chat) => chat.session) };
      case "_acpmux/harnesses":
        return harnesses;
      case "_acpmux/models":
        return models;
      case "_acpmux/attach": {
        const chat = chats.get(String(params.sessionId))!;
        return { session: chat.session, lastSeq: chat.events.length, events: chat.events };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chats.get(String(params.sessionId))?.events.length ?? 0 };
      case "session/new": {
        // acpmux starts the harness on its default and reports it.
        const sessionId = `0190a000-0000-7000-8000-0000000001${String(++started).padStart(2, "0")}`;
        const chat: Chat = { session: summary(sessionId, { cwd: params.cwd ?? CWD }), events: [] };
        chats.set(sessionId, chat);
        setTimeout(() => changed(chat, "created"), 0);
        return { sessionId, models: { currentModelId: DEFAULT, availableModels: claudeModels } };
      }
      case "session/set_model": {
        const chat = chats.get(String(params.sessionId))!;
        chat.session = { ...chat.session, model: String(params.modelId) };
        record(chat, "model", { modelId: params.modelId, atSpawn: true });
        changed(chat, "model");
        return {};
      }
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let holdNextPrompt = false;
  const url = (hash: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&cwd=${encodeURIComponent(CWD)}&${hash}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt") {
            calls.push({ method: message.method, params: message.params ?? {} });
            const hold = holdNextPrompt;
            holdNextPrompt = false;
            prompted(message.params ?? {}, hold);
          } else if (message.id !== undefined) {
            const result = answer(message.method, message.params ?? {});
            if (result !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          }
          for (const check of checks) check();
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

  const CHIP = ".acpmux-model-name";
  let probes = 0;
  /// The chip's text once the page has taken everything the daemon sent and drawn it: another chat
  /// listed after them lands behind them on the socket, so the page lists it only once it has taken
  /// the rest (the agent's own report of its default among them); two painted frames follow.
  async function settledChip(page: Page): Promise<string | null> {
    const sessionId = `probe-${++probes}`;
    broadcast("_acpmux/session_changed", {
      sessionId,
      session: summary(sessionId, { cwd: "/elsewhere" }),
      kind: "created",
    });
    await page.waitForFunction(
      (sessionId) =>
        (window as any).cmuxAcpmuxDebug
          .chatState()
          .sessions.some((session: { sessionId: string }) => session.sessionId === sessionId),
      sessionId,
      { timeout: 15_000 },
    );
    for (let frame = 0; frame < 2; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    return (await page.locator(CHIP).first().textContent()) ?? null;
  }
  /// Cmd-Ctrl-M and the model button open the same compact picker. Search there for the model,
  /// then click its name; this covers both New Tab and a started chat. The row is split: its name
  /// picks the model and its effort item ("Medium ›", after the name) opens the model's levels. In
  /// the compact menu (#30194) the effort item sits near the row's middle, so a click on the row's
  /// centre opens the levels instead of picking the model.
  async function pickModel(page: Page, id: string) {
    await page.locator(".acpmux-model .acpmux-picker-button").first().waitFor();
    await page.keyboard.press("Meta+Control+m");
    const menu = page.locator(".acpmux-quick-menu").first();
    await menu.waitFor();
    const name = claudeModels.find((model) => model.id === id)?.shortName;
    if (!name) throw new Error(`unknown test model ${id}`);
    await menu.getByRole("searchbox").fill(name);
    await menu
      .getByRole("menuitemradio", { name, exact: false })
      .first()
      .locator(".acpmux-quick-label")
      .click();
  }
  /// Checks run once the daemon has taken each message.
  const checks = new Set<() => void>();
  function until(what: string, done: () => boolean): Promise<void> {
    if (done()) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const check = () => {
        if (!done()) return;
        checks.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        checks.delete(check);
        reject(new Error(`timed out waiting for ${what}: ${JSON.stringify(calls.map((c) => c.method))}`));
      }, 10_000);
      checks.add(check);
    });
  }
  /// The model acpmux ran each prompt on: the session's last set_model before it, else the default.
  function promptModels(sessionId: string): string[] {
    let current = DEFAULT;
    const ran: string[] = [];
    for (const call of calls) {
      if (call.params.sessionId !== sessionId) continue;
      if (call.method === "session/set_model") current = String(call.params.modelId);
      if (call.method === "session/prompt") ran.push(current);
    }
    return ran;
  }

  test("a model picked on the New Tab chip starts the chat and stays after its first turn", async () => {
    calls.length = 0;
    const context = await browser!.newContext({ viewport: { width: 1000, height: 760 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await page.goto(url("newtab"));
    await page.locator(".nt-field").waitFor();
    await page.waitForFunction((selector) => !!document.querySelector(selector)?.textContent, CHIP);
    expect(await settledChip(page)).toBe("Opus 5.5");
    await pickModel(page, PICK);
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    await page.locator(".nt-field").click();
    await page.keyboard.type("Add retry to the uploader");
    await page.keyboard.press("Enter");
    await until("the first prompt", () => calls.some((call) => call.method === "session/prompt"));
    const prompt = calls.find((call) => call.method === "session/prompt")!;
    const sessionId = String(prompt.params.sessionId);
    await page.getByText("Answered on").waitFor();
    expect(promptModels(sessionId)).toEqual([PICK]);
    await page.getByText(`Answered on ${PICK}.`).waitFor();
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    // The next send stays on it too.
    await page.locator(".acpmux-composer [contenteditable], .acpmux-composer textarea").first().click();
    await page.keyboard.type("And log each retry");
    await page.keyboard.press("Enter");
    await until("the second prompt", () => promptModels(sessionId).length === 2);
    expect(promptModels(sessionId)).toEqual([PICK, PICK]);
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    await context.close();
  });

  test("a model picked while a turn runs holds for the next send", async () => {
    calls.length = 0;
    const sessionId = "0190a000-0000-7000-8000-0000000002f1";
    const chat: Chat = { session: summary(sessionId, { title: "Uploader retry", turnCount: 1 }), events: [] };
    chats.set(sessionId, chat);
    record(chat, "user_message", { text: "Add retry to the uploader", promptId: "p0", turnId: "turn-p0" });
    record(chat, "turn_started", { prompt: "Add retry to the uploader", promptId: "p0", turnId: "turn-p0" });
    reply(chat, "Retry added.");
    record(chat, "turn_result", { status: "completed" });
    const context = await browser!.newContext({ viewport: { width: 1000, height: 760 } });
    const page = await context.newPage();
    await installPaintedFrames(page);
    await page.goto(url(`session=${sessionId}`));
    await page.getByText("Retry added.").waitFor();
    expect(await settledChip(page)).toBe("Opus 5.5");
    // A turn starts and keeps running.
    holdNextPrompt = true;
    await page.locator(".acpmux-composer [contenteditable], .acpmux-composer textarea").first().click();
    await page.keyboard.type("Now log each retry");
    await page.keyboard.press("Enter");
    await until("the running turn", () => holding?.sessionId === sessionId);
    // The pick while it runs.
    await pickModel(page, PICK);
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    // The turn ends on the model it started on; the agent reports what it runs.
    holding!.finish();
    holding = undefined;
    await page
      .getByText(/Answered on/)
      .first()
      .waitFor();
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    await page.locator(".acpmux-composer [contenteditable], .acpmux-composer textarea").first().click();
    await page.keyboard.type("And add a test");
    await page.keyboard.press("Enter");
    await until("the next prompt", () => promptModels(sessionId).length === 2);
    expect(promptModels(sessionId)).toEqual([DEFAULT, PICK]);
    await page.getByText(`Answered on ${PICK}.`).waitFor();
    expect(await settledChip(page)).toBe("Sonnet 5.5");
    await context.close();
  });
});
