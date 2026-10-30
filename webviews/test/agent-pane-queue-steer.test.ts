// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Queued and steering prompts as Leo saw them on cosmic-gray (2026-10-13): the queued prompts drew
// under the chat's pull request bar, one truncated line each, a prompt sent now looked like any
// queued one, and a steer's bubble never said whether the agent took it. The page is the pane's dev
// entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux that replays a recorded chat: a turn that opened a pull request and is still
// writing its reply, with prompts queued behind it.
//
// - The queued prompts sit under the pull request bar, over the composer (the
//   bottom stack's order, #20521), never under either; the list is named "Queued prompts" (its rows
//   carry no header or number, Leo 2026-10-21), and a long one opens whole
//   (acpmux lists only a 200-character preview; the pane keeps the text its `queued` record had).
// - A prompt sent now to an agent that cannot steer reads "Steering" in the queue, apart from the
//   queued ones, and its bubble's read receipt reads read once it runs.
// - A steer's read receipt (in its bubble's hover row, Claude Code desktop's ✓ / ✓✓) is one check
//   while the reply it went into still streams, and two once the agent's next message starts; a
//   second steer in the same step does not mark the first read. No "Steering" / "Steered" line
//   shows under the bubble (Leo, 2026-10-20).
//
// - A queued prompt shows one line, cut with an ellipsis, until it is opened, in WebKit (the engine
//   cmux NEXT draws with) too: a live run showed a five-line prompt whole before any click.
//
// The stand-in sends what acpmux sends: the attach's `kinds` filter its page and its live events,
// with acpmux's list of transcript records (cmux-tui/crates/acpmux/src/hub/paging.rs). A live run
// lost "Steering" and "Sent now" because acpmux never streamed `queue_order` to the pane.
//
// Real Chromium and WebKit from Playwright; CI fails the file when either cannot launch
// (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-queue-steer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-queue-steer: skipping (run `bunx playwright install chromium webkit`)");
    describe.skip("queue and steer", () => test("chromium and webkit", () => {}));
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
  /// acpmux's mux records in the `transcript` kind (paging.rs `TRANSCRIPT_MUX_KINDS`).
  const TRANSCRIPT_MUX_KINDS = new Set([
    "user_message",
    "queued",
    "dequeued",
    "queue_removed",
    "prompt_retracted",
    "turn_started",
    "turn_result",
    "permission_request",
    "permission_auto",
    "permission_decision",
    "permission_group",
    "permission_chat_allowance",
    "message_superseded",
    "failover",
    "forked",
    "imported",
    "session_offer",
    "session_offer_decision",
    "mode",
    "model",
    "stopped",
    "exited",
  ]);
  /// acpmux's `EventFilter::matches`: a category or an exact record kind; none passes everything.
  let kinds: string[] | undefined;
  const passes = (rec: { dir: string; kind: string }) =>
    !kinds ||
    kinds.some(
      (kind) =>
        kind === "all" ||
        (kind === "transcript" && (rec.dir === "in" || TRANSCRIPT_MUX_KINDS.has(rec.kind))) ||
        (kind === "mux" && rec.dir === "mux") ||
        kind === rec.kind,
    );
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
    if (passes(rec)) socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: rec }));
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

  /// acpmux's `_acpmux/queue_edit` (queue_edit.rs `send_queued_now`): to an agent that cannot
  /// steer, a prompt sent now goes first (`queue_order` with `next`) and the running turn is
  /// cancelled; it runs once that turn ends. The test ends the turn itself.
  const onQueueEdit = (edit: { promptId?: string; op?: string }): unknown => {
    if (edit.op !== "send_now" || steering) return { ok: false };
    const id = String(edit.promptId);
    const order = [id, ...queue.map((q) => q.promptId).filter((q) => q !== id)];
    setTimeout(() => send(["mux", "queue_order", { promptId: id, order, next: true }]), 0);
    return { ok: true, outcome: "interrupt" };
  };
  function answer(ws: Socket, method: string, params: { kinds?: string[] } = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        socket = ws;
        kinds = params.kinds;
        return { session: summary(), lastSeq: seq, events: history.filter((rec) => passes(rec as never)) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      case "_acpmux/queue_edit":
        return onQueueEdit(params as never);
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  let wkBrowser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { kinds?: string[] } };
          const result = answer(ws, message.method, message.params);
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
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
    wkBrowser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await wkBrowser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(
    agentSteers: boolean,
    viewport = { width: 900, height: 760 },
    more: Step[] = [],
    engine: "chromium" | "webkit" = "chromium",
  ): Promise<Page> {
    steering = agentSteers;
    seq = 0;
    history = [];
    queue = [];
    socket = undefined;
    kinds = undefined;
    for (const step of [...opening, ...more]) send(step);
    const page = await (engine === "webkit" ? wkBrowser! : browser!).newPage({ viewport });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    // A cold dev server's first load can stall in CI: the first page waits longer.
    await page.locator(".acpmux-queued", { hasText: "space thing" }).waitFor({ timeout: 60_000 });
    await installPaintedFrames(page);
    return page;
  }
  /// Streams `text` onto the reply (message m1) and waits for it to draw: the page has handled
  /// every record sent before it.
  const caughtUp = async (page: Page, text: string) => {
    send(["in", "agent_message_chunk", say(text, "m1")]);
    await page.locator(".acpmux-scroll", { hasText: text }).waitFor({ timeout: 10_000 });
  };
  /// Unread steers have queue controls; sent/read prompts have the normal hover footer.
  const footer = (page: Page, text: string, read: boolean) =>
    page.locator(".cv-user", { hasText: text }).locator(read ? ".cv-user__time" : ".cv-user__pending");

  describe("queued and steering prompts", () => {
    test("queued prompts sit between the pull request bar and the composer, named Queued prompts, and a long one opens whole", async () => {
      const page = await openChat(true);
      const dock = page.locator(".acpmux-pr-dock");
      await dock.waitFor();
      // acpmux's later listing carries only the preview.
      changed();
      await caughtUp(page, "queued prompts.");
      const list = await page.locator(".acpmux-composer-queue").boundingBox();
      const bar = await dock.boundingBox();
      // A chat that has sent shows no location strip (#20869): the queue stands on the card.
      const composer = await page.locator(".acpmux-composer-box").boundingBox();
      expect(bar!.y + bar!.height).toBeLessThanOrEqual(list!.y + 1);
      expect(list!.y + list!.height).toBeLessThanOrEqual(composer!.y + 1);
      expect(await page.locator(".acpmux-queue-header").count()).toBe(0);
      expect(await page.locator(".acpmux-composer-queue").getAttribute("aria-label")).toBe("Queued prompts (2)");
      const long = page.locator(".acpmux-queued-text", { hasText: "the pr thing" });
      await long.click();
      await expect(long.getAttribute("aria-expanded")).resolves.toBe("true");
      expect(await long.innerText()).toBe(LONG);
      await page.close();
    });

    test("in WebKit a queued prompt shows one line until it is opened, then all of it", async () => {
      const FIVE = "alpha one\nbravo two\ncharlie three\ndelta four\necho five";
      const page = await openChat(
        true,
        undefined,
        [["mux", "queued", { text: FIVE, promptId: "q-5", turnId: "turn-5" }]],
        "webkit",
      );
      const text = page.locator(".acpmux-queued-text", { hasText: "alpha one" });
      await text.waitFor();
      // A line is the chat font's (#26523 scaled queued prompts with the chat font size).
      const line = await text.evaluate((el) => parseFloat(getComputedStyle(el).lineHeight));
      // One line, closed.
      const closed = (await text.boundingBox())!.height;
      expect(closed).toBeLessThanOrEqual(line + 1);
      await text.click();
      await expect(text.getAttribute("aria-expanded")).resolves.toBe("true");
      // All five lines once opened.
      const opened = (await text.boundingBox())!.height;
      expect(opened).toBeGreaterThanOrEqual(5 * line - 1);
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
      // The prompt has opened, and the list has come to rest fitted to it: a frame for the fit,
      // then its max-height transition (#24718) and any other finite animation run out.
      await page.locator('.acpmux-queued-text[aria-expanded="true"]', { hasText: "the pr thing" }).waitFor();
      await page.evaluate(async () => {
        await window.cmuxPaintFrame();
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        for (let tries = 0; tries < 20 && finite().some((animation) => animation.playState === "running"); tries++) {
          await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
          await window.cmuxPaintFrame();
        }
      });
      const box = async (selector: string) => (await page.locator(selector).first().boundingBox())!;
      const list = await box(".acpmux-composer-queue");
      const scroller = await box(".acpmux-scroll");
      const dock = await box(".acpmux-pr-dock");
      const composer = await box(".acpmux-composer-box");
      // Every queued prompt shows whole: the list never hides part of one. A list past its cap
      // scrolls and rests on whole rows (ComposerQueue fitList), so a prompt is in it or wholly
      // under its edge; a font that wraps the opened prompt further (CI's) takes this one past it.
      const [content, cap] = await page
        .locator(".acpmux-composer-queue")
        .evaluate((el) => [
          el.scrollHeight,
          parseFloat(getComputedStyle(el).getPropertyValue("--acpmux-queue-max")) || 132,
        ]);
      for (const row of await page.locator(".acpmux-queued").all()) {
        const r = (await row.boundingBox())!;
        if (content > cap + 1 && r.y >= list.y + list.height - 1) continue;
        expect(r.y).toBeGreaterThanOrEqual(list.y - 1);
        expect(r.y + r.height).toBeLessThanOrEqual(list.y + list.height + 1);
      }
      // The transcript runs under the stack to the pane's bottom (bottomStack.css), and the stack
      // holds the question above the pull requests, the pull requests above the queue and the
      // queue above the composer.
      const card = await box(".acpmux-permission-card");
      const stack = await box(".acpmux-main > .acpmux-dock");
      expect(stack.y).toBeLessThanOrEqual(card.y + 1);
      expect(Math.abs(scroller.y + scroller.height - (stack.y + stack.height))).toBeLessThanOrEqual(1);
      expect(card.y + card.height).toBeLessThanOrEqual(dock.y + 1);
      expect(dock.y + dock.height).toBeLessThanOrEqual(list.y + 1);
      // The queue shows its own bottom edge: nothing below tucks it under.
      expect(list.y + list.height).toBeLessThanOrEqual(composer.y + 1);
      await page.close();
    });

    test("a prompt sent now to an agent that cannot steer reads Steering, then read under its bubble", async () => {
      const page = await openChat(false);
      send(["mux", "queued", { text: "stop and fix the space thing first", promptId: "q-now", turnId: "turn-4" }]);
      send(["mux", "queue_order", { promptId: "q-now", order: ["q-now", "q-1", "q-2"], next: true }]);
      const now = page.locator(".acpmux-queued", { hasText: "fix the space thing first" });
      await now.locator(".acpmux-queued-kind", { hasText: "Steering" }).waitFor({ timeout: 10_000 });
      // The queued prompts carry no number (Leo, 2026-10-21).
      expect(await page.locator(".acpmux-queued-mark").count()).toBe(0);
      send(["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }]);
      send(["mux", "dequeued", { promptId: "q-now" }]);
      send([
        "mux",
        "user_message",
        { text: "stop and fix the space thing first", promptId: "q-now", turnId: "turn-4" },
      ]);
      await footer(page, "fix the space thing first", true).waitFor({ state: "attached", timeout: 10_000 });
      expect(await page.locator(".cv-user__steer").count()).toBe(0);
      await page.close();
    });

    test("Steer on a queued prompt keeps its row, reading Steering, until it runs (live run, 2026-10-14)", async () => {
      // A live run: after Send now (now Steer) the row went at once and nothing showed until the stopped turn
      // ended, because the queue hid the row as if it were leaving.
      const page = await openChat(false);
      const row = page.locator(".acpmux-queued", { hasText: "space thing" });
      await row.hover();
      // A queued row shows Steer, Delete and ⋯ (ChatGPT's order, 2026-10-21): click Steer by its name.
      await row.getByRole("button", { name: "Steer", exact: true }).click();
      await row.locator(".acpmux-queued-kind", { hasText: "Steering" }).waitFor({ timeout: 10_000 });
      // The stopped turn has not ended yet: once the page has handled what came after Steer, the
      // row still shows.
      await caughtUp(page, "queue order.");
      expect(await row.isVisible()).toBe(true);
      send(["mux", "turn_result", { status: "cancelled", turnId: "turn-1" }]);
      send(["mux", "dequeued", { promptId: "q-2" }]);
      send([
        "mux",
        "user_message",
        { text: "also man what happened with the space thing", promptId: "q-2", turnId: "turn-3" },
      ]);
      await footer(page, "space thing", true).waitFor({ state: "attached", timeout: 10_000 });
      await row.waitFor({ state: "detached", timeout: 10_000 });
      await page.close();
    });

    test("a steer keeps queue controls while its reply streams and switches to hover actions once read", async () => {
      const page = await openChat(true);
      send(["mux", "user_message", { text: "use the cache dir", promptId: "s-1", turnId: "turn-1", steer: true }]);
      await footer(page, "use the cache dir", false).waitFor({ state: "attached", timeout: 10_000 });
      // The rest of the reply it went into still streams: not read yet.
      await caughtUp(page, "remapped paths.");
      expect(await footer(page, "use the cache dir", false).count()).toBe(1);
      // The agent's next message answers the steer.
      send(["in", "agent_message_chunk", say("Using the cache dir now.", "m2")]);
      await footer(page, "use the cache dir", true).waitFor({ state: "attached", timeout: 10_000 });
      expect(await page.locator(".cv-user", { hasText: "use the cache dir" }).innerText()).not.toContain("Steer");
      await page.close();
    });

    test("a second steer in the same step leaves the first unread until the agent reads both", async () => {
      const page = await openChat(true);
      send(["mux", "user_message", { text: "use the cache dir", promptId: "s-1", turnId: "turn-1", steer: true }]);
      send(["mux", "user_message", { text: "and keep the old path", promptId: "s-2", turnId: "turn-1", steer: true }]);
      await footer(page, "and keep the old path", false).waitFor({ state: "attached", timeout: 10_000 });
      expect(await footer(page, "use the cache dir", false).count()).toBe(1);
      send(["in", "agent_message_chunk", say("Using the cache dir and the old path.", "m2")]);
      await footer(page, "use the cache dir", true).waitFor({ state: "attached", timeout: 10_000 });
      await footer(page, "and keep the old path", true).waitFor({ state: "attached", timeout: 10_000 });
      await page.close();
    });
  });
});
