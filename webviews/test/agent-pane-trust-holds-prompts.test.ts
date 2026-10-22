// l10n-allow-file: test fixture prompts, folders and questions, not shipped UI.
// Leo 2026-10-21 (P0): a pending trust prompt must never block steering, sending, or answering a
// question. While the chat folder's trust question was open the pane turned Send off (and steer
// with it), hid the chat's permission, question and secret cards, and kept at most one refused
// prompt to send after Trust. Now Send stays on: every prompt sent while the question is open waits
// in the composer's queue under "Waiting for folder trust" and goes, in order, after Trust; Not now
// leaves them there to edit or remove. The chat's question card stays under the trust question and
// its answer goes at once (acpmux takes it whatever the folder's trust).
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon whose folders have no trust answer yet.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-trust-holds-prompts.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-trust-holds-prompts: skipping (run `bunx playwright install chromium`)");
    describe.skip("trust holds prompts", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const WARM = "0190a000-0000-7000-8000-0000000000f0";
  const HELD = "0190a000-0000-7000-8000-0000000000f1";
  const NOT_NOW = "0190a000-0000-7000-8000-0000000000f2";
  const ASKING = "0190a000-0000-7000-8000-0000000000f3";
  const START = Date.now() - 90_000;
  const QUESTION = "Which auth method should the API use?";
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const done: Step[] = [
    ["mux", "user_message", { text: "Read the README" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Read it." } },
        },
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const rawInput = {
    questions: [
      {
        question: QUESTION,
        header: "Auth method",
        multiSelect: false,
        options: [{ label: "OAuth 2.0" }, { label: "API keys" }, { label: "Passkeys" }],
      },
    ],
  };
  const toolCall = {
    toolCallId: "toolu_ask",
    title: `Question: ${QUESTION}`,
    kind: "other",
    status: "pending",
    rawInput,
    _meta: { claude: { tool: "AskUserQuestion", interactive: true } },
  };
  const asking: Step[] = [
    ["mux", "user_message", { text: "Add auth to the API" }],
    ["mux", "turn_started", {}],
    ["in", "tool_call", { method: "session/update", params: { sessionId: "agent-1", update: { sessionUpdate: "tool_call", ...toolCall } } }],
    [
      "mux",
      "permission_request",
      {
        permissionId: "perm-ask",
        request: {
          sessionId: "agent-1",
          toolCall,
          options: [
            { optionId: "allow_once", name: "Answer", kind: "allow_once" },
            { optionId: "reject_once", name: "Reject", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const chats: Record<string, { cwd: string; steps: Step[]; status: string; shown: string }> = {
    [WARM]: { cwd: "/home/dev/warm", steps: done, status: "idle", shown: "Read it." },
    [HELD]: { cwd: "/home/dev/held", steps: done, status: "idle", shown: "Read it." },
    [NOT_NOW]: { cwd: "/home/dev/not-now", steps: done, status: "idle", shown: "Read it." },
    [ASKING]: { cwd: "/home/dev/asking", steps: asking, status: "waiting", shown: "Add auth to the API" },
  };
  const record = (sessionId: string, [dir, kind, msg]: Step, seq: number) => ({
    sessionId,
    seq,
    at: START + seq * 1000,
    dir,
    kind,
    msg,
  });
  const session = (sessionId: string) => ({
    sessionId,
    cwd: chats[sessionId]!.cwd,
    title: "Trust",
    harness: "claude",
    family: "claude",
    status: chats[sessionId]!.status,
    turnCount: 1,
    updatedAt: START,
  });

  /// Each folder's trust as acpmux has it: no answer until the pane gives one.
  const trust = new Map<string, string>();
  /// The prompts acpmux received, in order, and the asks it heard answered.
  const prompts: { sessionId: string; text: string }[] = [];
  const answers: Record<string, unknown>[] = [];
  function answer(method: string, params: Record<string, any> = {}): unknown {
    const id = typeof params.sessionId === "string" && chats[params.sessionId] ? params.sessionId : WARM;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: Object.keys(chats).map(session) };
      case "_acpmux/attach":
        return {
          session: session(id),
          lastSeq: chats[id]!.steps.length,
          events: chats[id]!.steps.map((step, index) => record(id, step, index + 1)),
        };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chats[id]!.steps.length };
      case "acp.trust.get":
        return { cwd: params.cwd, level: trust.get(params.cwd) ?? "unknown" };
      case "acp.trust.set":
        trust.set(params.cwd, params.level);
        return { cwd: params.cwd, level: params.level };
      case "session/prompt": {
        // acpmux's trust gate (`trust_gate.rs`): a folder without Trust gets no prompt.
        if (trust.get(chats[id]!.cwd) !== "trusted") return { refused: true };
        const text = (params.prompt as { type: string; text?: string }[])
          .filter((block) => block.type === "text")
          .map((block) => block.text)
          .join("");
        prompts.push({ sessionId: id, text });
        return { stopReason: "end_turn" };
      }
      case "_acpmux/permission_respond":
        answers.push(params);
        return {};
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (sessionId: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${sessionId}`;
  };
  /// A page of its own (its own storage: no folder's trust is remembered from another test).
  const open = async (sessionId: string) => {
    const context = await browser!.newContext({ viewport: { width: 900, height: 760 } });
    const page = await context.newPage();
    await page.goto(url(sessionId));
    await page.getByText(chats[sessionId]!.shown).first().waitFor({ timeout: 25_000 });
    return page;
  };
  const trustAsk = (page: Page) => page.locator(".acpmux-trust-ask");
  const field = (page: Page) => page.locator(".acpmux-composer .ProseMirror").first();
  const send = async (page: Page, text: string) => {
    await field(page).click();
    await page.keyboard.type(text);
    await page.keyboard.press("Enter");
  };
  const heldRow = (page: Page, text: string) => page.locator(".acpmux-queued", { hasText: text });
  /// Resolves once `test` holds, polling the stand-in's records (fails after 10 s).
  const until = async (test: () => boolean, what: string) => {
    for (let waited = 0; !test(); waited += 50) {
      if (waited > 10_000) throw new Error(`timed out waiting for ${what}`);
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params);
          const refused = (result as { refused?: boolean } | null)?.refused === true;
          ws.send(
            JSON.stringify(
              refused
                ? {
                    jsonrpc: "2.0",
                    id: message.id,
                    error: { code: -32000, message: "trust this folder first", data: { reason: "trust.pending" } },
                  }
                : { jsonrpc: "2.0", id: message.id, result },
            ),
          );
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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      try {
        const page = await open(WARM);
        await page.context().close();
        break;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  test("Send stays on under the trust question, and every prompt sent goes in order after Trust", async () => {
    const page = await open(HELD);
    await trustAsk(page).waitFor({ timeout: 10_000 });
    await field(page).click();
    await page.keyboard.type("first prompt");
    const sendButton = page.locator(".acpmux-send:not(.acpmux-cancel)").first();
    await sendButton.waitFor({ timeout: 10_000 });
    expect(await sendButton.isDisabled()).toBe(false);
    await page.keyboard.press("Enter");
    await send(page, "second prompt");
    // Both wait in the composer's queue, under their own header, and none reached acpmux.
    await heldRow(page, "first prompt").waitFor({ timeout: 10_000 });
    await heldRow(page, "second prompt").waitFor({ timeout: 10_000 });
    expect(await page.locator(".acpmux-queue-header", { hasText: "Waiting for folder trust" }).count()).toBe(1);
    expect(prompts.filter((prompt) => prompt.sessionId === HELD)).toEqual([]);

    await trustAsk(page).getByRole("button", { name: "Trust folder" }).click();
    await until(() => prompts.filter((prompt) => prompt.sessionId === HELD).length === 2, "both held prompts");
    expect(prompts.filter((prompt) => prompt.sessionId === HELD).map((prompt) => prompt.text)).toEqual([
      "first prompt",
      "second prompt",
    ]);
    await heldRow(page, "first prompt").waitFor({ state: "detached", timeout: 10_000 });
    await page.context().close();
  });

  test("Not now keeps the held prompts to edit or remove, and Trust later sends what is left", async () => {
    const page = await open(NOT_NOW);
    await trustAsk(page).waitFor({ timeout: 10_000 });
    await send(page, "keep this one");
    await send(page, "drop this one");
    await heldRow(page, "drop this one").waitFor({ timeout: 10_000 });

    await trustAsk(page).getByRole("button", { name: "Not now" }).click();
    await trustAsk(page).getByRole("button", { name: "Undo" }).waitFor({ timeout: 10_000 });
    // Not now drops nothing.
    expect(await heldRow(page, "keep this one").count()).toBe(1);
    expect(await heldRow(page, "drop this one").count()).toBe(1);
    await heldRow(page, "drop this one").locator('[data-action="delete"]').click();
    await heldRow(page, "drop this one").waitFor({ state: "detached", timeout: 10_000 });
    expect(await heldRow(page, "keep this one").count()).toBe(1);
    expect(prompts.filter((prompt) => prompt.sessionId === NOT_NOW)).toEqual([]);

    await trustAsk(page).getByRole("button", { name: "Undo" }).click();
    await trustAsk(page).getByRole("button", { name: "Trust folder" }).click();
    await until(() => prompts.some((prompt) => prompt.sessionId === NOT_NOW), "the kept prompt");
    expect(prompts.filter((prompt) => prompt.sessionId === NOT_NOW).map((prompt) => prompt.text)).toEqual([
      "keep this one",
    ]);
    await page.context().close();
  });

  test("the chat's question card shows under the open trust question and its answer goes at once", async () => {
    const page = await open(ASKING);
    await trustAsk(page).waitFor({ timeout: 10_000 });
    const choice = page.locator(".acpmux-question-row", { hasText: "API keys" });
    await choice.waitFor({ timeout: 10_000 });
    expect(await trustAsk(page).count()).toBe(1);
    await choice.click();
    await until(() => answers.some((params) => params.permissionId === "perm-ask"), "the question's answer");
    // A steer typed into the running turn waits for Trust too, with Send on.
    await send(page, "use OAuth after all");
    await heldRow(page, "use OAuth after all").waitFor({ timeout: 10_000 });
    expect(prompts.filter((prompt) => prompt.sessionId === ASKING)).toEqual([]);
    await page.context().close();
  });
});
