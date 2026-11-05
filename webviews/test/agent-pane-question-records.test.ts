// l10n-allow-file: test fixture prompts, questions and answers, not shipped UI.
// An agent's question (Claude Code AskUserQuestion here) shows as a card above the composer while
// it waits. Once answered it left nothing in the chat: the card went, and so did what the person
// chose. Codex and Claude Code keep a compact record where the question was asked. The transcript
// now keeps one, a compact card: the question with "OAuth 2.0" in grey under it for an answer,
// "Skipped" for a question declined and "Stopped before an answer" for one the turn's stop cancelled. It comes from acpmux's own log
// (`permission_request`, then its `permission_decision`), so a reload shows it as before, and it
// stays out of the turn's
// "Worked for" fold. The page is the pane's dev entry with its browser host, talking JSON-RPC to
// a stand-in acpmux daemon that can push live events.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-question-records.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-question-records: skipping (run `bunx playwright install chromium`)");
    describe.skip("question records", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const ANSWERED = "0190a000-0000-7000-8000-0000000000d1";
  const CANCELLED = "0190a000-0000-7000-8000-0000000000d2";
  const DECLINED = "0190a000-0000-7000-8000-0000000000d3";
  const LIVE = "0190a000-0000-7000-8000-0000000000d4";
  const LAG = "0190a000-0000-7000-8000-0000000000d5";
  const START = Date.now() - 90_000;
  const PROMPT = "Which auth method should the API use?";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const rawInput = {
    questions: [
      {
        question: PROMPT,
        header: "Auth method",
        multiSelect: false,
        options: [{ label: "OAuth 2.0" }, { label: "API keys" }, { label: "Passkeys" }],
      },
    ],
  };
  const toolCall = {
    toolCallId: "toolu_ask",
    title: `Question: ${PROMPT}`,
    kind: "other",
    status: "pending",
    rawInput,
    _meta: { claude: { tool: "AskUserQuestion", interactive: true } },
  };
  const asked: Step[] = [
    ["mux", "user_message", { text: "Add auth to the API" }],
    ["mux", "turn_started", {}],
    ["in", "tool_call", update({ sessionUpdate: "tool_call", ...toolCall })],
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
  const decision = (outcome: Record<string, unknown>): Step => [
    "mux",
    "permission_decision",
    { permissionId: "perm-ask", outcome },
  ];
  const answer = decision({
    outcome: "selected",
    optionId: "allow_once",
    _meta: { updatedInput: { ...rawInput, answers: { [PROMPT]: "OAuth 2.0" } } },
  });
  const ended = (reply: string, status: string): Step[] => [
    [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "toolu_ask", status: "completed" }),
    ],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: reply } }),
    ],
    ["mux", "turn_result", { status }],
  ];
  const record = (session: string, step: Step, seq: number) => {
    const [dir, kind, msg] = step;
    return { sessionId: session, seq, at: START + seq * 1000, dir, kind, msg };
  };
  const log = (session: string, steps: Step[]) => steps.map((step, index) => record(session, step, index + 1));
  const chats: Record<string, ReturnType<typeof record>[]> = {
    [ANSWERED]: log(ANSWERED, [...asked, answer, ...ended("Going with OAuth 2.0.", "completed")]),
    [CANCELLED]: log(CANCELLED, [...asked, decision({ outcome: "cancelled" }), ...ended("Stopped.", "cancelled")]),
    [DECLINED]: log(DECLINED, [
      ...asked,
      decision({ outcome: "selected", optionId: "reject_once" }),
      ...ended("I'll pick one myself.", "completed"),
    ]),
    [LIVE]: log(LIVE, asked),
    // The ask, its answer and the reply's first words reach the pane only through a resync.
    [LAG]: log(LAG, asked.slice(0, 3)),
  };
  const chunk = (text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", messageId: "reply-1", content: { type: "text", text } }),
  ];
  const missed = [asked[3]!, answer, chunk("Going with")].map((step, index) => record(LAG, step, 4 + index));
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Auth",
    harness: "claude",
    family: "claude",
    status: sessionId === LIVE || sessionId === LAG ? "waiting" : "idle",
    turnCount: 1,
    updatedAt: START,
  });

  function reply(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: Object.keys(chats).map(session) };
      case "_acpmux/attach": {
        const id = typeof params.sessionId === "string" && chats[params.sessionId] ? params.sessionId : ANSWERED;
        return { session: session(id), lastSeq: chats[id]!.length, events: chats[id] };
      }
      case "_acpmux/events":
        if (params.sessionId === LAG && Number(params.afterSeq) < 4)
          return { events: missed, hasMore: false, lastSeq: missed.length + 3 };
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const sockets = new Set<{ send(data: string): void }>();
  let liveSeq = asked.length;
  const push = (step: Step) => {
    const event = record(LIVE, step, ++liveSeq);
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  const open = async (session: string, shown: string) => {
    sockets.clear();
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(session));
    await page.getByText(shown).first().waitFor({ timeout: 25_000 });
    return page;
  };
  /// The transcript's question records, as their text reads.
  const records = (page: Page) =>
    page
      .locator(".acpmux-scroll")
      .locator(".acpmux-question-answered, .acpmux-question-cancelled")
      .evaluateAll((nodes) => nodes.map((node) => (node as HTMLElement).innerText.replace(/\s+/g, " ").trim()));
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
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: reply(message.method, message.params) }));
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
    for (let attempt = 1; ; attempt++) {
      try {
        await (await open(ANSWERED, "Going with OAuth 2.0.")).close();
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

  test("an answered question leaves what was chosen in the chat, outside the turn's fold", async () => {
    const page = await open(ANSWERED, "Going with OAuth 2.0.");
    await page.locator(".acpmux-question-answered").first().waitFor({ timeout: 5_000 });
    expect(await records(page)).toEqual([`Answered ${PROMPT} OAuth 2.0`]);
    await page.close();
  });

  test("a question the turn stopped or the person skipped says so", async () => {
    const cancelled = await open(CANCELLED, "Stopped.");
    await cancelled.locator(".acpmux-question-cancelled").first().waitFor({ timeout: 5_000 });
    expect(await records(cancelled)).toEqual([`${PROMPT} Stopped before an answer`]);
    await cancelled.close();
    const declined = await open(DECLINED, "I'll pick one myself.");
    await declined.locator(".acpmux-question-cancelled").first().waitFor({ timeout: 5_000 });
    expect(await records(declined)).toEqual([`${PROMPT} Skipped`]);
    await declined.close();
  });

  test("answered live, the card goes and the record takes its place", async () => {
    const page = await open(LIVE, "Add auth to the API");
    await page.getByRole("radio", { name: /OAuth 2\.0/ }).waitFor({ timeout: 5_000 });
    expect(await records(page)).toEqual([]);
    push(answer);
    await page.locator(".acpmux-question-answered").first().waitFor({ timeout: 5_000 });
    expect(await page.getByRole("radio", { name: /OAuth 2\.0/ }).count()).toBe(0);
    expect(await records(page)).toEqual([`Answered ${PROMPT} OAuth 2.0`]);
    // The work after the answer draws below its record, never in the row above it.
    push([
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "toolu_ask", status: "completed" }),
    ]);
    push([
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "read-auth",
        title: "Read src/auth.ts",
        kind: "read",
        status: "in_progress",
        rawInput: { file_path: "src/auth.ts" },
      }),
    ]);
    // While it runs the read draws no row of its own (Debug toggle agentPane.debug.codexToolRuns,
    // on by default): the live line at the turn's foot names it (Thinking.tsx), under the record.
    const live = page.locator(".cv-worked.is-below .cv-thinking", { hasText: "Read auth.ts" });
    await live.waitFor({ timeout: 5_000 });
    const line = await live.boundingBox();
    // Done, the line holds it until the next step (Leo, 2026-11-01: "it should just keep going");
    // once the next call runs, the read is its own row, under the record too.
    push([
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "read-auth", status: "completed" }),
    ]);
    push([
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "read-routes",
        title: "Read src/routes.ts",
        kind: "read",
        status: "in_progress",
        rawInput: { file_path: "src/routes.ts" },
      }),
    ]);
    const after = page.locator(".cv-tool__text", { hasText: "Read src/auth.ts" }).first();
    await after.waitFor({ timeout: 5_000 });
    const [record, read] = await Promise.all([
      page.locator(".acpmux-question-answered").first().boundingBox(),
      after.boundingBox(),
    ]);
    expect(line!.y).toBeGreaterThan(record!.y);
    expect(read!.y).toBeGreaterThan(record!.y);
    await page.close();
  });

  test("a resync that brings the answer keeps one record and the reply that streams after it whole", async () => {
    const page = await open(LAG, "Add auth to the API");
    const send = (message: Record<string, unknown>) => {
      for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
    };
    // acpmux dropped events for this client: the pane fetches them and replays them.
    send({ method: "_acpmux/lagged", params: { sessionIds: [LAG], dropped: 3 } });
    await page.getByText("Going with").first().waitFor({ timeout: 5_000 });
    send({ method: "_acpmux/event", params: record(LAG, chunk(" OAuth 2.0."), 7) });
    await page.getByText("Going with OAuth 2.0.").waitFor({ timeout: 5_000 });
    expect(await records(page)).toEqual([`Answered ${PROMPT} OAuth 2.0`]);
    await page.close();
  });
});
