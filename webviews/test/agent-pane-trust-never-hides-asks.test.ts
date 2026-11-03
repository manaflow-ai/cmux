// l10n-allow-file: test fixture prompts, folders and questions, not shipped UI.
// Leo 2026-10-21 (P0): a pending trust prompt must never block steering, sending, or answering a
// question. While the chat folder's trust question was open (or after Not now) the pane hid the
// chat's permission, question and secret cards (`holdsAsks`), so a turn already running waited on an
// ask nobody could see. acpmux takes an ask's answer whatever the folder's trust (only prompts pass
// its trust gate), so the question card stays under the trust question and its answer goes at once.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon whose folders have no trust answer yet.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-trust-never-hides-asks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-trust-never-hides-asks: skipping (run `bunx playwright install chromium`)");
    describe.skip("trust never hides asks", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const WARM = "0190a000-0000-7000-8000-0000000000f0";
  const ASKING = "0190a000-0000-7000-8000-0000000000f3";
  const DECLINED = "0190a000-0000-7000-8000-0000000000f5";
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
    [
      "in",
      "tool_call",
      {
        method: "session/update",
        params: { sessionId: "agent-1", update: { sessionUpdate: "tool_call", ...toolCall } },
      },
    ],
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
  // `turns`: the turns acpmux ran of the chat.
  const chats: Record<string, { cwd: string; steps: Step[]; status: string; shown: string; turns: number }> = {
    [WARM]: { cwd: "/home/dev/warm", steps: done, status: "idle", shown: "Read it.", turns: 0 },
    [ASKING]: { cwd: "/home/dev/asking", steps: asking, status: "waiting", shown: "Add auth to the API", turns: 1 },
    [DECLINED]: { cwd: "/home/dev/declined", steps: asking, status: "waiting", shown: "Add auth to the API", turns: 1 },
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
    turnCount: chats[sessionId]!.turns,
    updatedAt: START,
  });

  /// Each folder's trust as acpmux has it: no answer until the pane gives one.
  const trust = new Map<string, string>();
  /// The prompts acpmux received, in order, and the asks it heard answered.
  const prompts: { sessionId: string; text: string }[] = [];
  const answers: Record<string, unknown>[] = [];
  /// The waiters (`until`), checked each time the stand-in records a prompt or an answer.
  const recorded = new Set<() => void>();
  const heard = () => {
    for (const check of recorded) check();
  };
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
        // acpmux's trust gate (`trust_gate.rs`): a folder without Trust gets no prompt, except a
        // chat whose agent already runs, while the question is open (pending_passes).
        const level = trust.get(chats[id]!.cwd);
        if (level !== "trusted" && (level === "untrusted" || chats[id]!.turns === 0)) return { refused: true };
        const text = (params.prompt as { type: string; text?: string }[])
          .filter((block) => block.type === "text")
          .map((block) => block.text)
          .join("");
        prompts.push({ sessionId: id, text });
        heard();
        return { stopReason: "end_turn" };
      }
      case "_acpmux/permission_respond":
        answers.push(params);
        heard();
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
  /// Resolves once `test` holds, checked whenever the stand-in records something (fails after 10 s).
  const until = (test: () => boolean, what: string) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!test()) return;
        recorded.delete(check);
        clearTimeout(limit);
        resolve();
      };
      const limit = setTimeout(() => {
        recorded.delete(check);
        reject(new Error(`timed out waiting for ${what}`));
      }, 10_000);
      recorded.add(check);
      check();
    });

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

  test("a running chat's question card shows and answers under the open trust question", async () => {
    const page = await open(ASKING);
    await trustAsk(page).waitFor({ timeout: 10_000 });
    const choice = page.locator(".acpmux-question-row", { hasText: "API keys" });
    await choice.waitFor({ timeout: 10_000 });
    expect(await trustAsk(page).count()).toBe(1);
    await choice.click();
    await page.locator(".acpmux-question-submit").click();
    await until(() => answers.some((params) => params.sessionId === ASKING), "the question's answer");
    // The trust question stays: answering the agent's question answers nothing about the folder.
    expect(await trustAsk(page).count()).toBe(1);
    await page.context().close();
  });

  test("Not now leaves the running chat's question card answerable", async () => {
    const page = await open(DECLINED);
    await trustAsk(page).waitFor({ timeout: 10_000 });
    await trustAsk(page).getByRole("button", { name: "Not now" }).click();
    await trustAsk(page).getByRole("button", { name: "Undo" }).waitFor({ timeout: 10_000 });
    const choice = page.locator(".acpmux-question-row", { hasText: "Passkeys" });
    await choice.waitFor({ timeout: 10_000 });
    await choice.click();
    await page.locator(".acpmux-question-submit").click();
    await until(() => answers.some((params) => params.sessionId === DECLINED), "the declined chat's answer");
    await page.context().close();
  });
});
