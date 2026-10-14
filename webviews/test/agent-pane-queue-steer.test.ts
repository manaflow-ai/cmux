// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Queued and steering prompts as Leo saw them on cosmic-gray (2026-10-13): the queued prompts drew
// under the chat's pull request bar, one truncated line each, a prompt sent now looked like any
// queued one, and a steer's bubble never said whether the agent took it. The page is the pane's dev
// entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux that replays a recorded chat: a turn that opened a pull request and is still
// writing its reply, with prompts queued behind it.
//
// - The queued prompts sit above the pull request bar, under "Queued", and a long one opens whole
//   (acpmux lists only a 200-character preview; the pane keeps the text its `queued` record had).
// - A prompt sent now to an agent that cannot steer reads "Steering" in the queue, apart from the
//   queued ones, and "Sent now · stopped the turn" under its bubble once it runs.
// - A steer reads "Steering" under its bubble while the reply it went into still streams, and
//   "Steered" once the agent's next message starts; a second steer in the same step does not mark
//   the first read.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-queue-steer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-queue-steer: skipping (run `bunx playwright install chromium`)");
    describe.skip("queue and steer", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 13, 18, 50, 0);
  const LONG =
    "the pr thing blocks + the lower area being colored like that looks weird :( and the scrolling/streaming " +
    "text looks off when it reaches the bottom, also check that the queued prompts show in full when I open " +
    "them because right now I can only read the first line of what I asked";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string, messageId: string) =>
    update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// The recorded chat up to the moment the page opens: the turn opened a pull request and is
  /// writing its reply (message m1); two prompts wait behind it.
  const opening: Step[] = [
    ["mux", "user_message", { text: "Open the PR for the remapped cwd fix", promptId: "p-turn", turnId: "turn-1" }],
    ["mux", "turn_started", { turnId: "turn-1" }],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "gh pr create",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: 'gh pr create --title "Adopt a moved Claude chat" --body x' },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "https://github.com/acme/cmux/pull/20308\n" } }],
        rawOutput: { exit_code: 0 },
      }),
    ],
    ["in", "agent_message_chunk", say("Opened #20308. Now checking the ", "m1")],
    ["mux", "queued", { text: LONG, promptId: "q-1", turnId: "turn-2", position: 1 }],
    ["mux", "queued", { text: "also man what happened with the space thing", promptId: "q-2", turnId: "turn-3" }],
  ];
  let steering = true;
  let seq = 0;
  let history: Record<string, unknown>[] = [];
  let queue: { promptId: string; prompt: string }[] = [];
  const record = ([dir, kind, msg]: Step) => ({
    sessionId: SESSION,
    seq: ++seq,
    at: START + seq * 1000,
    dir,
    kind,
    msg,
  });
  /// acpmux lists a queued prompt's preview: its first 200 characters on one line.
  const preview = (text: string) => {
    const line = text.split(/\s+/).filter(Boolean).join(" ");
    return line.length > 200 ? `${line.slice(0, 200)}…` : line;
  };
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/cmux",
    title: "Open the PR for the remapped cwd fix",
    harness: "claude",
    status: "running",
    steering,
    queued: queue.length,
    queue: queue.map((q) => ({ promptId: q.promptId, prompt: preview(q.prompt) })),
    turn: { turnId: "turn-1", promptId: "p-turn", startedAt: START },
    updatedAt: START,
  });

  type Socket = { send(data: string): void };
  let socket: Socket | undefined;
  const send = (step: Step) => {
    const rec = record(step);
    history.push(rec);
    if (step[0] === "mux") {
      if (step[1] === "queued") queue.push({ promptId: String(step[2].promptId), prompt: String(step[2].text) });
      if (step[1] === "dequeued") queue = queue.filter((q) => q.promptId !== step[2].promptId);
    }
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
  };
  /// acpmux's session_changed, which lists the queue as previews.
  const changed = () =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, session: summary(), kind: "queue", seq },
      }),
    );

  function answer(ws: Socket, method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        socket = ws;
        return { session: summary(), lastSeq: seq, events: history };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      default:
        return null;
    }
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          const result = answer(ws, message.method);
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(
    agentSteers: boolean,
    viewport = { width: 900, height: 760 },
    more: Step[] = [],
  ): Promise<Page> {
    steering = agentSteers;
    seq = 0;
    history = [];
    queue = [];
    socket = undefined;
    for (const step of [...opening, ...more]) send(step);
    const page = await browser!.newPage({ viewport });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // A cold dev server's first load can stall in CI: the first page waits longer.
    await page.locator(".acpmux-queued", { hasText: "space thing" }).waitFor({ timeout: 60_000 });
    return page;
  }
  const bubbleMark = (page: Page, text: string) =>
    page.locator(".cv-user", { hasText: text }).locator(".cv-user__steer");

  describe("queued and steering prompts", () => {
    test("queued prompts sit above the pull request bar, under Queued, and a long one opens whole", async () => {
      const page = await openChat(true);
      const dock = page.locator(".acpmux-pr-dock");
      await dock.waitFor();
      // acpmux's later listing carries only the preview.
      changed();
      await page.waitForTimeout(200);
      const list = await page.locator(".acpmux-composer-queue").boundingBox();
      const bar = await dock.boundingBox();
      expect(list!.y + list!.height).toBeLessThanOrEqual(bar!.y + 1);
      expect(await page.locator(".acpmux-queue-header").innerText()).toContain("Queued");
      const long = page.locator(".acpmux-queued-text", { hasText: "the pr thing" });
      await long.click();
      await expect(long.getAttribute("aria-expanded")).resolves.toBe("true");
      expect(await long.innerText()).toBe(LONG);
      await page.close();
    });

    test("the queue takes its own place in the stack: nothing is cut off or drawn over", async () => {
      // The pane's size in a cmux window (Leo's recording, cosmic-gray).
      // The next command waits for an answer while the queue holds a long prompt.
      const asks: Step[] = [
        [
          "in",
          "tool_call",
          update({
            sessionUpdate: "tool_call",
            toolCallId: "t2",
            title: "gh pr merge",
            kind: "execute",
            status: "pending",
          }),
        ],
        [
          "mux",
          "permission_request",
          {
            permissionId: "perm-1",
            request: {
              toolCall: { toolCallId: "t2", title: "gh pr merge", kind: "execute" },
              options: [
                { optionId: "allow", name: "Allow once", kind: "allow_once" },
                { optionId: "deny", name: "Deny", kind: "reject_once" },
              ],
            },
          },
        ],
      ];
      const page = await openChat(true, { width: 900, height: 655 }, asks);
      await page.locator(".acpmux-pr-dock").waitFor();
      await page.locator(".acpmux-permission-card").waitFor();
      await page.locator(".acpmux-queued-text", { hasText: "the pr thing" }).click();
      await page.waitForTimeout(300);
      const box = async (selector: string) => (await page.locator(selector).first().boundingBox())!;
      const list = await box(".acpmux-composer-queue");
      const scroller = await box(".acpmux-scroll");
      const dock = await box(".acpmux-pr-dock");
      const composer = await box(".acpmux-composer");
      // Every queued prompt shows whole: the list never hides part of one.
      for (const row of await page.locator(".acpmux-queued").all()) {
        const r = (await row.boundingBox())!;
        expect(r.y).toBeGreaterThanOrEqual(list.y - 1);
        expect(r.y + r.height).toBeLessThanOrEqual(list.y + list.height + 1);
      }
      // The transcript ends above the question, the question above the queue, the queue above
      // the pull requests and the composer.
      const card = await box(".acpmux-permission-card");
      expect(scroller.y + scroller.height).toBeLessThanOrEqual(card.y + 1);
      expect(card.y + card.height).toBeLessThanOrEqual(list.y + 1);
      expect(scroller.y + scroller.height).toBeLessThanOrEqual(list.y + 1);
      // The queue shows its own bottom edge: nothing below tucks it under.
      expect(list.y + list.height + 4).toBeLessThanOrEqual(dock.y + 1);
      expect(dock.y + dock.height).toBeLessThanOrEqual(composer.y + 1);
      await page.close();
    });

    test("a prompt sent now to an agent that cannot steer reads Steering, then Sent now under its bubble", async () => {
      const page = await openChat(false);
      send(["mux", "queued", { text: "stop and fix the space thing first", promptId: "q-now", turnId: "turn-4" }]);
      send(["mux", "queue_order", { promptId: "q-now", order: ["q-now", "q-1", "q-2"], next: true }]);
      const now = page.locator(".acpmux-queued", { hasText: "fix the space thing first" });
      await now.locator(".acpmux-queued-kind", { hasText: "Steering" }).waitFor({ timeout: 10_000 });
      // The queued prompts still count from 1.
      expect(await page.locator(".acpmux-queued-mark").allInnerTexts()).toEqual(["1", "2"]);
      send(["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }]);
      send(["mux", "dequeued", { promptId: "q-now" }]);
      send([
        "mux",
        "user_message",
        { text: "stop and fix the space thing first", promptId: "q-now", turnId: "turn-4" },
      ]);
      await bubbleMark(page, "fix the space thing first")
        .getByText("Sent now · stopped the turn")
        .waitFor({ timeout: 10_000 });
      await page.close();
    });

    test("a steer reads Steering while the reply it went into streams, and Steered once the agent reads it", async () => {
      const page = await openChat(true);
      send(["mux", "user_message", { text: "use the cache dir", promptId: "s-1", turnId: "turn-1", steer: true }]);
      const mark = bubbleMark(page, "use the cache dir");
      await mark.getByText("Steering").waitFor({ timeout: 10_000 });
      // The rest of the reply it went into still streams: not read yet.
      send(["in", "agent_message_chunk", say("remapped paths.", "m1")]);
      await page.waitForTimeout(200);
      expect(await mark.innerText()).toContain("Steering");
      // The agent's next message answers the steer.
      send(["in", "agent_message_chunk", say("Using the cache dir now.", "m2")]);
      await mark.getByText("Steered · the agent read it").waitFor({ timeout: 10_000 });
      await page.close();
    });

    test("a second steer in the same step leaves the first Steering until the agent reads both", async () => {
      const page = await openChat(true);
      send(["mux", "user_message", { text: "use the cache dir", promptId: "s-1", turnId: "turn-1", steer: true }]);
      send(["mux", "user_message", { text: "and keep the old path", promptId: "s-2", turnId: "turn-1", steer: true }]);
      const first = bubbleMark(page, "use the cache dir");
      const second = bubbleMark(page, "and keep the old path");
      await second.getByText("Steering").waitFor({ timeout: 10_000 });
      expect(await first.innerText()).toContain("Steering");
      expect(await first.innerText()).not.toContain("Steered");
      send(["in", "agent_message_chunk", say("Using the cache dir and the old path.", "m2")]);
      await first.getByText("Steered · the agent read it").waitFor({ timeout: 10_000 });
      await second.getByText("Steered · the agent read it").waitFor({ timeout: 10_000 });
      await page.close();
    });
  });
});
