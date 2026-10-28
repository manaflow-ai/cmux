// l10n-allow-file: test fixture prompts and commands, not shipped UI.
// A single permission card (an ask outside the grouped panel) went once answered and left nothing:
// the grouped panel shows a receipt, the single card none. Codex and Claude Code keep the answer
// with the turn. The transcript now keeps a one-line receipt where the ask was answered: "Allowed:
// Run npm test", "Always allowed: …", "Denied: …", or "Not answered: …" for one the turn's end
// cancelled. It comes from acpmux's log (`permission_request`, then its `permission_decision`), so
// a reload shows it again. An ask a chat in Full access answered unasked (`permission_auto` with
// `fullAccess`) leaves "Approved: … (Full access)"; one a policy answered still leaves none. The page is the pane's dev entry with its browser host, talking
// JSON-RPC to a stand-in acpmux daemon that can push live events.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-permission-receipt.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-permission-receipt: skipping (run `bunx playwright install chromium`)");
    describe.skip("permission receipt", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const ALLOWED = "0190a000-0000-7000-8000-0000000000f1";
  const ALWAYS = "0190a000-0000-7000-8000-0000000000f2";
  const DENIED = "0190a000-0000-7000-8000-0000000000f3";
  const CANCELLED = "0190a000-0000-7000-8000-0000000000f4";
  const LIVE = "0190a000-0000-7000-8000-0000000000f5";
  const LAG = "0190a000-0000-7000-8000-0000000000f6";
  const FULL = "0190a000-0000-7000-8000-0000000000f7";
  const POLICY = "0190a000-0000-7000-8000-0000000000f8";
  const START = Date.now() - 90_000;
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const toolCall = {
    toolCallId: "call-test",
    title: "Run npm test",
    kind: "execute",
    status: "pending",
    rawInput: { command: "npm test" },
  };
  const asked: Step[] = [
    ["mux", "user_message", { text: "Check the build" }],
    ["mux", "turn_started", {}],
    ["in", "tool_call", update({ sessionUpdate: "tool_call", ...toolCall })],
    [
      "mux",
      "permission_request",
      {
        permissionId: "perm-test",
        request: {
          sessionId: "agent-1",
          toolCall,
          options: [
            { optionId: "allow_once", name: "Allow", kind: "allow_once" },
            { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
            { optionId: "reject_once", name: "Reject", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const decided = (outcome: Record<string, unknown>): Step => [
    "mux",
    "permission_decision",
    { permissionId: "perm-test", outcome },
  ];
  const picked = (optionId: string) => decided({ outcome: "selected", optionId });
  /// Claude Code's own guard in bypassPermissions, answered by acpmux without a card: by Full access
  /// (`fullAccess`, the mode) or, without it, by the chat's policy.
  const guard = {
    toolCallId: "call-guard",
    title: "rm -rf f/*",
    kind: "execute",
    status: "pending",
    rawInput: { command: "rm -rf f/*" },
  };
  const unasked = (fullAccess?: string): Step[] => [
    ["mux", "user_message", { text: "Make the contact sheet" }],
    ["mux", "turn_started", {}],
    ["in", "tool_call", update({ sessionUpdate: "tool_call", ...guard })],
    [
      "mux",
      "permission_auto",
      {
        permissionId: "perm-guard",
        policy: "ask",
        optionId: "allow_once",
        ...(fullAccess ? { fullAccess } : {}),
        request: {
          sessionId: "agent-1",
          toolCall: guard,
          options: [
            { optionId: "allow_once", name: "Allow", kind: "allow_once" },
            { optionId: "allow_always", name: "Allow for this session", kind: "allow_always" },
            { optionId: "reject_once", name: "Reject", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const ended = (reply: string, status = "completed"): Step[] => [
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
    [ALLOWED]: log(ALLOWED, [...asked, picked("allow_once"), ...ended("Tests pass.")]),
    [ALWAYS]: log(ALWAYS, [...asked, picked("allow_always"), ...ended("Tests pass, always.")]),
    [DENIED]: log(DENIED, [...asked, picked("reject_once"), ...ended("Skipped the tests.")]),
    [CANCELLED]: log(CANCELLED, [...asked, decided({ outcome: "cancelled" }), ...ended("Stopped.", "cancelled")]),
    [LIVE]: log(LIVE, asked),
    // The ask, its answer and the reply's first words reach the pane only through a resync.
    [LAG]: log(LAG, asked.slice(0, 3)),
    [FULL]: log(FULL, [...unasked("bypassPermissions"), ...ended("Sheet made.")]),
    [POLICY]: log(POLICY, [...unasked(), ...ended("Sheet made by policy.")]),
  };
  const chunk = (text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", messageId: "reply-1", content: { type: "text", text } }),
  ];
  const missed = [asked[3]!, picked("allow_once"), chunk("Tests")].map((step, index) => record(LAG, step, 4 + index));
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Build",
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
        const id = typeof params.sessionId === "string" && chats[params.sessionId] ? params.sessionId : ALLOWED;
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
  /// The transcript's permission receipts, as their text reads, with the turn's work opened.
  const receipts = async (page: Page) => {
    const fold = (expanded: boolean) =>
      page.locator(`.acpmux-scroll button[aria-expanded='${expanded}']`, { hasText: /Worked for|stopped after/ });
    if (await fold(false).count()) {
      await fold(false).first().click();
      await fold(true).first().waitFor({ timeout: 5_000 });
    }
    return page
      .locator(".acpmux-scroll .acpmux-permission-record")
      .evaluateAll((nodes) => nodes.map((node) => (node as HTMLElement).innerText.replace(/\s+/g, " ").trim()));
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
        await (await open(ALLOWED, "Tests pass.")).close();
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

  test("an answered ask leaves a receipt that says how it was answered", async () => {
    for (const [chat, shown, receipt] of [
      [ALLOWED, "Tests pass.", "Allowed: Run npm test"],
      [ALWAYS, "Tests pass, always.", "Always allowed: Run npm test"],
      [DENIED, "Skipped the tests.", "Denied: Run npm test"],
      [CANCELLED, "Stopped.", "Not answered: Run npm test"],
    ] as const) {
      const page = await open(chat, shown);
      expect(await receipts(page)).toEqual([receipt]);
      await page.close();
    }
  });

  test("an ask Full access answered unasked leaves its own receipt; one a policy answered none", async () => {
    let page = await open(FULL, "Sheet made.");
    expect(await receipts(page)).toEqual(["Approved: rm -rf f/* (Full access)"]);
    await page.close();
    page = await open(POLICY, "Sheet made by policy.");
    expect(await receipts(page)).toEqual([]);
    await page.close();
  });

  test("answered live, the card goes and its receipt shows in the turn", async () => {
    const page = await open(LIVE, "Check the build");
    await page.locator(".acpmux-permission-ask").waitFor({ timeout: 5_000 });
    expect(await receipts(page)).toEqual([]);
    push(picked("allow_once"));
    await page.locator(".acpmux-permission-record").first().waitFor({ timeout: 5_000 });
    expect(await page.locator(".acpmux-permission-ask").count()).toBe(0);
    expect(await receipts(page)).toEqual(["Allowed: Run npm test"]);
    await page.close();
  });

  test("a resync that brings the answer keeps one receipt and the reply that streams after it whole", async () => {
    const page = await open(LAG, "Check the build");
    const send = (message: Record<string, unknown>) => {
      for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", ...message }));
    };
    // acpmux dropped events for this client: the pane fetches them and replays them.
    send({ method: "_acpmux/lagged", params: { sessionIds: [LAG], dropped: 3 } });
    await page.getByText("Tests").first().waitFor({ timeout: 5_000 });
    send({ method: "_acpmux/event", params: record(LAG, chunk(" pass."), 7) });
    await page.getByText("Tests pass.").waitFor({ timeout: 5_000 });
    expect(await receipts(page)).toEqual(["Allowed: Run npm test"]);
    await page.close();
  });
});
