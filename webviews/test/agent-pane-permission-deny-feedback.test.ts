// l10n-allow-file: test fixture prompts, commands and instructions, not shipped UI.
// Claude Code's permission prompt offers "No, and tell Claude what to do differently": it declines
// the tool and takes what the person says instead. The pane's card only declined and focused the
// composer, and only Claude's ask said so. Every ask with a deny option now has the action: it opens
// a field in the card, and sending it declines the ask, then sends the text into the running turn
// (a steer), so the agent hears why and what to do instead. Sent empty, it only declines; Cancel
// goes back to the options without answering. The page is the pane's dev entry with its browser
// host, talking JSON-RPC to a stand-in acpmux daemon that records what the pane asks of it.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-permission-deny-feedback.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-permission-deny-feedback: skipping (run `bunx playwright install chromium`)");
    describe.skip("deny with feedback", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CLAUDE = "0190a000-0000-7000-8000-0000000000e1";
  const CODEX = "0190a000-0000-7000-8000-0000000000e2";
  const START = Date.now() - 90_000;
  const harnessOf: Record<string, string> = { [CLAUDE]: "claude", [CODEX]: "codex" };
  const optionsOf: Record<string, { optionId: string; name: string; kind: string }[]> = {
    [CLAUDE]: [
      { optionId: "allow_once", name: "Allow", kind: "allow_once" },
      { optionId: "allow_always", name: "Always allow", kind: "allow_always" },
      { optionId: "reject_once", name: "Reject", kind: "reject_once" },
    ],
    [CODEX]: [
      { optionId: "approved", name: "Approve", kind: "allow_once" },
      { optionId: "denied", name: "Decline", kind: "reject_once" },
    ],
  };
  const events = (session: string) => {
    const toolCall = {
      toolCallId: "call-test",
      title: "Run npm test",
      kind: "execute",
      status: "pending",
      rawInput: { command: "npm test" },
    };
    const steps: [string, string, Record<string, unknown>][] = [
      ["mux", "user_message", { text: "Check the build" }],
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
        { permissionId: "perm-test", request: { sessionId: "agent-1", toolCall, options: optionsOf[session] } },
      ],
    ];
    return steps.map(([dir, kind, msg], index) => ({
      sessionId: session,
      seq: index + 1,
      at: START + (index + 1) * 1000,
      dir,
      kind,
      msg,
    }));
  };
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Build",
    harness: harnessOf[sessionId],
    family: harnessOf[sessionId],
    status: "waiting",
    turnCount: 1,
    updatedAt: START,
  });
  /// What the pane asked of acpmux, by method, in order.
  let asked: { method: string; params: Record<string, any> }[] = [];

  function reply(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(CLAUDE), session(CODEX)] };
      case "_acpmux/attach": {
        const id = params.sessionId === CODEX ? CODEX : CLAUDE;
        return { session: session(id), lastSeq: 4, events: events(id) };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  const open = async (session: string) => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(session));
    await page.locator(".acpmux-permission-ask").waitFor({ timeout: 25_000 });
    asked = [];
    return page;
  };
  const answers = () =>
    asked.flatMap(({ method, params }) =>
      method === "_acpmux/permission_respond"
        ? [`respond ${params.optionId}`]
        : method === "session/prompt"
          ? [
              `prompt${params._meta?.acpmux?.steer ? " (steer)" : ""} ${params.prompt
                ?.map((block: { text?: string }) => block.text ?? "")
                .join("")}`,
            ]
          : [],
    );
  const settle = async (page: Page, count: number) => {
    for (let tries = 0; tries < 40 && answers().length < count; tries++) await page.waitForTimeout(50);
    await page.waitForTimeout(200);
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
          asked.push({ method: message.method, params: message.params ?? {} });
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
        await (await open(CLAUDE)).close();
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

  test("Claude's 'tell Claude what to do differently' declines, then sends what the person said", async () => {
    const page = await open(CLAUDE);
    await page.getByRole("button", { name: "No, tell Claude what to do differently" }).click();
    const field = page.getByRole("textbox", { name: "Tell the agent what to do instead" });
    await field.waitFor({ timeout: 5_000 });
    expect(answers()).toEqual([]);
    await field.fill("Run only the unit tests");
    await field.press("Enter");
    await settle(page, 2);
    expect(answers()).toEqual(["respond reject_once", "prompt (steer) Run only the unit tests"]);
    await page.close();
  });

  test("every ask with a deny option offers it; sent empty, it only declines", async () => {
    const page = await open(CODEX);
    // Codex keeps codex-acp's own Decline, and the action sits beside it.
    await page.getByRole("button", { name: "Decline" }).waitFor({ timeout: 5_000 });
    await page.getByRole("button", { name: "Deny and tell the agent what to do instead" }).click();
    await page.getByRole("button", { name: "Deny and send" }).click();
    await settle(page, 1);
    expect(answers()).toEqual(["respond denied"]);
    await page.close();
  });

  test("Cancel goes back to the options without answering", async () => {
    const page = await open(CODEX);
    await page.getByRole("button", { name: "Deny and tell the agent what to do instead" }).click();
    await page.getByRole("textbox", { name: "Tell the agent what to do instead" }).fill("Never mind");
    await page.getByRole("button", { name: "Cancel" }).click();
    await page.getByRole("button", { name: "Approve" }).waitFor({ timeout: 5_000 });
    expect(await page.getByRole("textbox", { name: "Tell the agent what to do instead" }).count()).toBe(0);
    await page.waitForTimeout(200);
    expect(answers()).toEqual([]);
    await page.close();
  });
});
