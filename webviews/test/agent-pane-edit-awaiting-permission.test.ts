// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// An edit still waiting for its permission is not an edit yet (cx-5rkd2, dogfood run hq #1893).
// Claude's bridge sends the proposed edit, diff included, before it asks: the transcript drew it as
// "Edited <file> +3 -5" with View changes while the permission card asked whether to allow it. The
// call now reads as a plain tool row until the edit runs, and the Edited card follows. A second
// edit that arrives while the first one's question is open waits too (cx-p5fgx, dogfood run 2):
// Claude asks one question at a time, so its diff came before its own question and read as
// "Edited upload_test.sh +1 -1" with nothing on disk.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-edit-awaiting-permission.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-edit-awaiting-permission: skipping (run `bunx playwright install chromium`)");
    describe.skip("edit awaiting permission", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const WAITING = "0190a000-0000-7000-8000-0000000000d1";
  const ALLOWED = "0190a000-0000-7000-8000-0000000000d2";
  const SECOND = "0190a000-0000-7000-8000-0000000000d3";
  const FIRST_RAN = "0190a000-0000-7000-8000-0000000000d4";
  const EARLY = "0190a000-0000-7000-8000-0000000000d5";
  const TEST_FILE = "/home/dev/uploader/install_test.sh";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const FILE = "/home/dev/uploader/install.sh";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  // As Claude's bridge sends it: the call is in progress, with its diff, while it asks.
  const asking: Step[] = [
    ["mux", "user_message", { text: "Tighten the retry comment" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "e1",
        title: "Edit install.sh",
        kind: "edit",
        status: "in_progress",
        content: [{ type: "diff", path: FILE, oldText: "a\nb\n", newText: "a\nretry\nb\n" }],
      }),
    ],
    [
      "mux",
      "permission_request",
      {
        permissionId: "p1",
        request: {
          toolCall: { toolCallId: "e1", title: "Edit install.sh", kind: "edit" },
          options: [
            { optionId: "allow", name: "Allow", kind: "allow_once" },
            { optionId: "deny", name: "Deny", kind: "reject_once" },
          ],
        },
      },
    ],
  ];
  const allowed: Step[] = [
    ...asking,
    ["mux", "permission_decision", { permissionId: "p1", optionId: "allow" }],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "e1",
        status: "completed",
        content: [{ type: "diff", path: FILE, oldText: "a\nb\n", newText: "a\nretry\nb\n" }],
      }),
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  // The test's edit arrives, diff included, while the question about install.sh is still open.
  const second: Step[] = [
    ...asking,
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "e2",
        title: "Edit install_test.sh",
        kind: "edit",
        status: "in_progress",
        content: [{ type: "diff", path: TEST_FILE, oldText: "3\n", newText: "5\n" }],
      }),
    ],
  ];
  // acpmux names a call as its block starts (#22402): the test's edit is named before the question
  // about install.sh opens, and its input (diff included) arrives while that question is open.
  const early: Step[] = [
    ["mux", "user_message", { text: "Tighten the retry comment" }],
    ["mux", "turn_started", {}],
    asking[2],
    [
      "in",
      "tool_call",
      update({ sessionUpdate: "tool_call", toolCallId: "e2", title: "Edit", kind: "edit", status: "pending" }),
    ],
    asking[3],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "e2",
        title: "Edit install_test.sh",
        kind: "edit",
        status: "in_progress",
        content: [{ type: "diff", path: TEST_FILE, oldText: "3\n", newText: "5\n" }],
      }),
    ],
  ];
  // install.sh is allowed and runs; the test's edit has not asked yet.
  const firstRan: Step[] = [
    ...second,
    ["mux", "permission_decision", { permissionId: "p1", optionId: "allow" }],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "e1",
        status: "completed",
        content: [{ type: "diff", path: FILE, oldText: "a\nb\n", newText: "a\nretry\nb\n" }],
      }),
    ],
  ];
  const chats = new Map(
    [
      [WAITING, asking],
      [ALLOWED, allowed],
      [SECOND, second],
      [FIRST_RAN, firstRan],
      [EARLY, early],
    ].map(([sessionId, steps]) => {
      const events = (steps as Step[]).map(([dir, kind, msg], index) => ({
        sessionId,
        seq: index + 1,
        at: START + index * 1000,
        dir,
        kind,
        msg,
      }));
      const session = {
        sessionId,
        cwd: "/home/dev/uploader",
        title: "Retry comment",
        harness: "claude",
        family: "claude",
        status: sessionId === ALLOWED ? "idle" : "running",
        turnCount: 1,
        updatedAt: START,
      };
      return [sessionId as string, { session, events }] as const;
    }),
  );

  function answer(method: string, params: Record<string, any> | undefined): unknown {
    const chat = chats.get(String(params?.sessionId ?? ""));
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [...chats.values()].map((entry) => entry.session) };
      case "_acpmux/attach":
        return chat ? { session: chat.session, lastSeq: chat.events.length, events: chat.events } : null;
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chat?.events.length ?? 0 };
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here first.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(ALLOWED));
        await warm.getByText("Tighten the retry comment").waitFor({ timeout: 25_000 });
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

  test("an edit waiting for its permission reads as the tool call, not Edited", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(WAITING));
    await page.getByText("Tighten the retry comment").waitFor();
    await page.getByText("Edit install.sh").first().waitFor();
    expect(await page.locator(".acpmux-edited").count()).toBe(0);
    expect(await page.getByText(/^Edited/).count()).toBe(0);
    expect(await page.getByRole("button", { name: "View changes" }).count()).toBe(0);
    await page.close();
  });

  test("an edit that arrives while another waits for its permission is not Edited either", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(SECOND));
    await page.getByText("Tighten the retry comment").waitFor();
    await page.getByText("Edit install_test.sh").first().waitFor();
    expect(await page.locator(".acpmux-edited").count()).toBe(0);
    expect(await page.getByText(/^Edited/).count()).toBe(0);
    await page.close();
  });

  test("an edit named early whose input arrives while another waits is not Edited either", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(EARLY));
    await page.getByText("Tighten the retry comment").waitFor();
    await page.getByText("Edit install_test.sh").first().waitFor();
    expect(await page.locator(".acpmux-edited").count()).toBe(0);
    expect(await page.getByText(/^Edited/).count()).toBe(0);
    await page.close();
  });

  test("when the first edit runs, only its file reads as Edited", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(FIRST_RAN));
    await page.getByText("Tighten the retry comment").waitFor();
    // A run with a change still waiting for its permission keeps its tool rows, so the held call
    // stays in sight (conversation/turns.ts `codexRuns`); the turn's edited-files card comes once
    // it runs. The edit that ran reads as Edited with its change, the held one as its call.
    const run = page.locator(".acpmux-activity", { hasText: "install_test.sh" });
    await run.waitFor();
    const labels = (await run.locator(".cv-tool__text").allTextContents()).map((label) => label.trim());
    expect(labels).toContain("Edited install.sh+1-0");
    expect(labels).toContain("Edit install_test.sh");
    expect(labels.some((label) => label.startsWith("Edited install_test.sh"))).toBe(false);
    await page.close();
  });

  test("once allowed and run, the edit reads as Edited with its changes", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(ALLOWED));
    await page.getByText("Tighten the retry comment").waitFor();
    const card = page.locator(".acpmux-edited");
    await card.waitFor();
    expect(await card.locator(".acpmux-edited-sub .acpmux-diff-add").textContent()).toBe("+1");
    await page.close();
  });
});
