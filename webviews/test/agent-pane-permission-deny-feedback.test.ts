// l10n-allow-file: test fixture prompts, commands and instructions, not shipped UI.
// Claude Code's permission prompt offers "No, and tell Claude what to do differently": it declines
// the tool and takes what the person says instead. The pane's card only declined and focused the
// composer, and only Claude's ask said so. Every ask with a deny option now has the action: Deny
// opens a field in the card ("Tell Claude what to do differently" for Claude), and sending it
// declines the ask, then sends the text into the running turn (a steer), so the agent hears why and
// what to do instead. Sent empty, it only declines; Cancel goes back to the buttons without answering. The page is the pane's dev entry with its browser
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
  /// While set, acpmux refuses the pane's permission answer (the ask was answered elsewhere).
  let refuseDeny = false;

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
  /// Called each time the pane asks acpmux something.
  let onAsk: (() => void) | undefined;
  /// Resolves once acpmux has heard `count` answers.
  const heard = (count: number) =>
    new Promise<void>((resolve) => {
      const check = () => {
        if (answers().length < count) return;
        onAsk = undefined;
        resolve();
      };
      onAsk = check;
      check();
    });
  /// Whether the keyboard is in the composer: a deny acpmux took has finished (sendFeedback).
  const inComposer = (page: Page) =>
    page.waitForFunction(() => Boolean(document.activeElement?.closest(".acpmux-composer")), undefined, {
      timeout: 10_000,
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
          asked.push({ method: message.method, params: message.params ?? {} });
          onAsk?.();
          if (message.id !== undefined && refuseDeny && message.method === "_acpmux/permission_respond")
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, error: { code: -32000, message: "already answered" } }),
            );
          else if (message.id !== undefined)
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
    await page.getByRole("button", { name: "Deny" }).click();
    const field = page.getByRole("textbox", { name: "Tell Claude what to do differently" });
    await field.waitFor({ timeout: 5_000 });
    expect(answers()).toEqual([]);
    await field.fill("Run only the unit tests");
    await field.press("Enter");
    // The keyboard goes back to the composer, as a plain deny's does, once the text has gone too.
    await inComposer(page);
    expect(answers()).toEqual(["respond reject_once", "prompt (steer) Run only the unit tests"]);
    await page.close();
  });

  test("a deny acpmux refuses keeps the field and what was typed", async () => {
    const page = await open(CLAUDE);
    refuseDeny = true;
    try {
      await page.getByRole("button", { name: "Deny" }).click();
      const field = page.getByRole("textbox", { name: "Tell Claude what to do differently" });
      await field.fill("Use pnpm");
      await field.press("Enter");
      // The refusal is back: the field can be typed in again and has the keyboard.
      await page.waitForFunction(
        () => {
          const active = document.activeElement;
          return (
            active instanceof HTMLTextAreaElement && active.closest(".acpmux-permission-feedback") && !active.readOnly
          );
        },
        undefined,
        { timeout: 10_000 },
      );
      expect(answers()).toEqual(["respond reject_once"]);
      expect(await field.inputValue()).toBe("Use pnpm");
    } finally {
      refuseDeny = false;
    }
    await page.close();
  });

  test("an Allow acpmux refuses says so on the card, and the ask can be answered again", async () => {
    const page = await open(CODEX);
    refuseDeny = true;
    try {
      await page.getByRole("button", { name: "Allow once" }).click();
      // The pane's own wiring (App answerPermission) hands the refusal to the card.
      await page.locator(".acpmux-permission-refused").waitFor({ timeout: 10_000 });
      expect(answers()).toEqual(["respond approved"]);
    } finally {
      refuseDeny = false;
    }
    await page.getByRole("button", { name: "Allow once" }).click();
    await heard(2);
    expect(answers()).toEqual(["respond approved", "respond approved"]);
    await page.close();
  });

  test("every ask with a deny option offers it; sent empty, it only declines", async () => {
    const page = await open(CODEX);
    // Codex's Decline is the card's Deny.
    await page.getByRole("button", { name: "Deny" }).click();
    await page.getByRole("button", { name: "Deny and send" }).click();
    await inComposer(page);
    expect(answers()).toEqual(["respond denied"]);
    await page.close();
  });

  test("Cancel goes back to the options without answering", async () => {
    const page = await open(CODEX);
    await page.getByRole("button", { name: "Deny" }).click();
    await page.getByRole("textbox", { name: "Tell the agent what to do instead" }).fill("Never mind");
    await page.getByRole("button", { name: "Cancel" }).click();
    await page.getByRole("button", { name: "Allow once" }).waitFor({ timeout: 5_000 });
    expect(await page.getByRole("textbox", { name: "Tell the agent what to do instead" }).count()).toBe(0);
    // The keyboard goes back to Deny, which opened the field.
    expect(await page.evaluate(() => document.activeElement?.getAttribute("aria-label"))).toBe("Deny");
    // Cancel sent nothing: the next answer the card gives is the first acpmux hears.
    await page.getByRole("button", { name: "Allow once" }).click();
    await heard(1);
    expect(answers()).toEqual(["respond approved"]);
    await page.close();
  });
});
