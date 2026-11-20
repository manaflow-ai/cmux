// l10n-allow-file: test fixture prompts, replies and subagent names, not shipped UI.
// A subagent's own pane (a tab on the chat's session that opens on `subagent:<id>`,
// subagents/subagentPanes.ts) shows the subagent with a composer of its own (Leo 2026-11-03:
// "currently it says "read only" on the subagents in cmux-next. we should improve that"). It never
// draws the chat's composer, queue or pull request bars: they are the chat's. What is typed in the
// subagent's composer goes to the chat as a SendMessage relay naming the subagent's agentId
// (subagents/subagentMessage.ts), since a Claude subagent has no acpmux session of its own.
// Leo 2026-10-20: a reviewer's pane showed the chat's queued "this is a bit spammy" and its #663
// bar. The chat's own pane keeps all of them. The page is the pane's dev entry with its browser
// host, talking JSON-RPC to a stand-in acpmux daemon; the app's `subagent:` reveal is the page
// bridge's `revealTurn`.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("subagent-pane-own-state.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("subagent-pane-own-state: skipping (run `bunx playwright install chromium`)");
    describe.skip("subagent pane state", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e1";
  const START = Date.now() - 60_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const command = 'gh pr create --title "Add retry"';
  // A turn that opened a pull request, started a reviewer and still works, with a prompt queued
  // behind it.
  const steps: Step[] = [
    ["mux", "user_message", { text: "Open the PR and have an agent review it" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "https://github.com/acme/uploader/pull/663" } }],
        rawOutput: { exit_code: 0 },
      }),
    ],
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned" },
        {
          subagents: [
            {
              id: "a1",
              parent: null,
              name: "Reviewer",
              state: "running",
              startedAt: START + 4000,
              agentId: "a39e817af38ddf5e7",
            },
          ],
        },
      ),
    ],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The reviewer is on it." } }),
    ],
    ["mux", "queued", { text: "this is a bit spammy", promptId: "q1", position: 1 }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + (index + 1) * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Release review",
    harness: "claude",
    family: "claude",
    status: "working",
    turnCount: 1,
    // Claude Code takes a prompt into a running turn (acpmux `steering`).
    steering: true,
    // acpmux's list holds the queue; the replayed `queued` record gives the prompt's whole text.
    queue: [{ promptId: "q1", prompt: "this is a bit spammy" }],
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: steps.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const open = async (): Promise<Page> => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText("The reviewer is on it.").waitFor({ timeout: 25_000 });
    return page;
  };
  /// What the pane's bottom shows: the chat's composer, its queued prompt and its pull request bar,
  /// and a subagent's own composer: its placeholder and the line naming the chat that passes it on.
  const bottom = (page: Page) =>
    page.evaluate(() => ({
      composer: document.querySelectorAll(".acpmux-composer:not(.acpmux-subagent-composer)").length,
      queued: [...document.querySelectorAll(".acpmux-queued")].map((row) => row.textContent ?? ""),
      subagent: document.querySelectorAll(".acpmux-subagent-composer").length,
      placeholder:
        document.querySelector(".acpmux-subagent-composer [aria-label]")?.getAttribute("aria-label")?.trim() ?? "",
      via: document.querySelector(".cv-subagent-composer-via")?.textContent?.trim() ?? "",
      text: document.body.textContent ?? "",
    }));
  /// A message whose relay acpmux takes and whose turn never ends (the stand-in daemon never answers it).
  const RUNNING_TURN = "Keep an eye on the flaky test";
  /// Every prompt the stand-in daemon was sent, as its text.
  const prompts: string[] = [];
  /// Resolves with the first prompt sent after it was made that holds `text`.
  let awaited: { text: string; resolve(sent: string): void } | undefined;
  const promptWith = (text: string) => new Promise<string>((resolve) => (awaited = { text, resolve }));
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: unknown };
          if (/prompt/i.test(message.method)) {
            const sent = JSON.stringify(message.params ?? null);
            prompts.push(sent);
            if (awaited && sent.includes(awaited.text)) awaited.resolve(sent);
          }
          // A prompt whose turn keeps running: acpmux takes it at once and answers when the turn ends,
          // which here is never.
          const params = message.params as { _meta?: { acpmux?: { promptId?: string } } } | undefined;
          if (/prompt/i.test(message.method) && JSON.stringify(params ?? null).includes(RUNNING_TURN)) {
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                method: "_acpmux/prompt_accepted",
                params: { promptId: params?._meta?.acpmux?.promptId },
              }),
            );
            return;
          }
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

  test("the chat's own pane keeps its composer, its queue and its pull request bar", async () => {
    const page = await open();
    await page.locator(".acpmux-queued").first().waitFor({ timeout: 10_000 });
    const shown = await bottom(page);
    expect(shown.composer).toBe(1);
    expect(shown.queued.some((text) => text.includes("this is a bit spammy"))).toBe(true);
    expect(shown.subagent).toBe(0);
    await page.close();
  });

  test("a subagent's pane shows its own composer, with none of the chat's queue or bars", async () => {
    const page = await open();
    await page.locator(".acpmux-queued").first().waitFor({ timeout: 10_000 });
    await page.evaluate(() =>
      (window as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } }).cmuxAcpmuxBridge?.revealTurn?.(
        "subagent:a1",
      ),
    );
    await page.locator(".cv-subagent-of").waitFor({ timeout: 10_000 });
    const shown = await bottom(page);
    expect(shown.composer).toBe(0);
    expect(shown.queued).toEqual([]);
    expect(shown.subagent).toBe(1);
    expect(shown.text).not.toContain("Read only");
    expect(shown.placeholder).toBe("Message Reviewer");
    expect(shown.via).toContain("Release review");
    // "Subagent of" shows the chat in this pane: the chat's composer, queue and bar are back.
    await page.locator(".cv-subagent-of__pill").click();
    await page.locator(".acpmux-queued").first().waitFor({ timeout: 10_000 });
    const chat = await bottom(page);
    expect(chat.composer).toBe(1);
    expect(chat.subagent).toBe(0);
    await page.close();
  });

  test("a message typed in a subagent's pane goes to its chat as a SendMessage to its agentId", async () => {
    const page = await open();
    await page.evaluate(() =>
      (window as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } }).cmuxAcpmuxBridge?.revealTurn?.(
        "subagent:a1",
      ),
    );
    await page.locator(".acpmux-subagent-composer").waitFor({ timeout: 10_000 });
    prompts.length = 0;
    const arrived = promptWith("Also check the retry tests");
    await page.locator('.acpmux-subagent-composer [aria-label="Message Reviewer"]').click();
    await page.keyboard.type("Also check the retry tests");
    await page.keyboard.press("Enter");
    await page.waitForFunction(() => !document.querySelector(".acpmux-subagent-composer .ProseMirror")?.textContent);
    // The test's own timeout ends a wait for a prompt that never comes.
    const sent = await arrived;
    expect(sent).toContain(CHAT);
    expect(sent).toContain("SendMessage");
    expect(sent).toContain("a39e817af38ddf5e7");
    expect(sent).toContain("Reviewer");
    // A steer: the chat's turn runs and its agent steers, so its next step reads it, not after the
    // turn (an idle chat gets a prompt of its own: subagentMessage.test.ts subagentRelaySteers).
    expect(sent).toContain('"steer":true');
    await page.close();
  });

  test("a message the chat took is no longer held by the pane while the chat's turn runs on", async () => {
    const page = await open();
    await page.evaluate(() =>
      (window as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } }).cmuxAcpmuxBridge?.revealTurn?.(
        "subagent:a1",
      ),
    );
    await page.locator(".acpmux-subagent-composer").waitFor({ timeout: 10_000 });
    const arrived = promptWith(RUNNING_TURN);
    await page.locator('.acpmux-subagent-composer [aria-label="Message Reviewer"]').click();
    await page.keyboard.type(RUNNING_TURN);
    await page.keyboard.press("Enter");
    await arrived;
    // The chat's send settles when the turn ends, which it never does here; the relay settled when
    // acpmux took it, so a web update or a page release no longer waits on it.
    await page.waitForFunction(
      () => (window as { cmuxWebSwap?: { hold(): string | null } }).cmuxWebSwap?.hold() !== "subagents.draft-unsaved",
      undefined,
      { timeout: 10_000 },
    );
    await page.close();
  });
});
