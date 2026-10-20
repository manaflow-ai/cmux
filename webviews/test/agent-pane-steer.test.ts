// Queue and steer while a turn runs, in the real agent pane (cx-xtg0.3). The page is the pane's dev
// entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon whose one chat has a turn running, and which answers prompts as acpmux
// does: a plain prompt waits behind the turn (`queued`), a steer goes into it (`user_message`).
//
// - Enter sends now: into the turn for an agent that steers (`_meta.acpmux.steer`), else with no
//   queue flag, so acpmux stops the running turn and runs it next (its default since 2026-10-20,
//   "We do not like queuing here"). ⌘Enter stops the turn and sends now.
// - ⌥Enter queues (`_meta.acpmux.queue`): the queue row shows the prompt and the composer is free for
//   the next one. The prompt shows there from the send on, never first as a transcript bubble.
// - ⌘Enter steers, and an agent that cannot steer is told to stop the turn and run it next
//   (`_meta.acpmux.interrupt`); the button says so.
// - Esc on an empty composer stops the turn.
// - Stop always frees the chat: acpmux's forced end of a turn whose agent ignored the cancel says
//   so, and a turn still open a few seconds after Stop stops showing as working (cosmic-gray,
//   2026-10-14: a chat stuck "running" after `/permissions`, Stop doing nothing).
// - A slash command that runs only in Claude Code's terminal (`/permissions`) is not sent: the
//   composer keeps it and names the control to use.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-steer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-steer: skipping (run `bunx playwright install chromium`)");
    describe.skip("queue and steer", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "steer-session";
  const turn = {
    turnId: "turn-1",
    promptId: "p-turn",
    startedAt: Date.now(),
    prompt: "Refactor the parser",
  };
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Refactor the parser",
    harness: "claude",
    status: "running",
    steering: false,
    queued: 0,
    queue: [],
    turn,
    updatedAt: Date.now(),
  };
  const opening = [
    {
      sessionId: SESSION,
      seq: 1,
      at: Date.now(),
      dir: "mux",
      kind: "user_message",
      msg: { text: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
    {
      sessionId: SESSION,
      seq: 2,
      at: Date.now(),
      dir: "mux",
      kind: "turn_started",
      msg: { prompt: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
  ];
  let seq = opening.length;
  const prompts: Record<string, any>[] = [];
  const cancels: Record<string, any>[] = [];
  /// `_acpmux/events` reads: a lag resync's refetch, which rebuilds the transcript.
  let eventReads = 0;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opening.length, events: opening };
      case "_acpmux/events":
        eventReads += 1;
        return { events: [], hasMore: false, lastSeq: seq };
      default:
        return null;
    }
  }

  /// acpmux's answer to a prompt while the turn runs: no reply until its turn, only an event.
  function prompted(ws: { send(data: string): void }, params: Record<string, any>, id?: number): void {
    prompts.push(params);
    const meta = params._meta?.acpmux ?? {};
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    // A steer goes into the turn; a prompt with no queue flag stops it and starts (acpmux's
    // default): both echo as `user_message`. Only `_meta.acpmux.queue` waits (`queued`).
    const msg = meta.steer
      ? { text, promptId: meta.promptId, turnId: "turn-1", steer: true }
      : !meta.queue
        ? { text, promptId: meta.promptId, turnId: `turn-${meta.promptId}` }
        : {
            text,
            promptId: meta.promptId,
            turnId: `turn-${meta.promptId}`,
            position: prompts.length,
          };
    const event = {
      sessionId: SESSION,
      seq: ++seq,
      at: Date.now(),
      dir: "mux",
      kind: meta.steer || !meta.queue ? "user_message" : "queued",
      msg,
    };
    const deliver = () => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    // acpmux's `queued` record can come a beat after the send (130 ms on cosmic-gray, 2026-10-13).
    if (text === "queued a beat late") setTimeout(deliver, 400);
    else deliver();
    // acpmux checks a queued prompt again when its turn comes (`check_dispatch`) and may refuse it.
    if (text === "refused at its turn")
      setTimeout(() => {
        const error = { code: -32602, message: "web_control.refused: the chat's mode changed" };
        ws.send(JSON.stringify({ jsonrpc: "2.0", id, error }));
      }, 300);
  }

  let socket: { send(data: string): void } | undefined;
  /// An acpmux record, as the attached page gets it.
  const record = (kind: string, msg: Record<string, unknown>) =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: SESSION, seq: ++seq, at: Date.now(), dir: "mux", kind, msg },
      }),
    );

  /// acpmux dropped events for the page: it refetches and replays the whole transcript.
  async function lag(page: Page): Promise<void> {
    const before = eventReads;
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [SESSION] } }));
    const deadline = Date.now() + 5_000;
    while (eventReads === before && Date.now() < deadline) await page.waitForTimeout(50);
    expect(eventReads).toBeGreaterThan(before);
    await page.waitForTimeout(300);
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
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, any>;
          };
          if (message.method === "session/prompt") return prompted(ws, message.params ?? {}, message.id);
          if (message.method === "session/cancel") cancels.push(message.params ?? {});
          socket = ws;
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method),
              }),
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(): Promise<Page> {
    prompts.length = 0;
    cancels.length = 0;
    const page = await browser!.newPage({
      viewport: { width: 900, height: 760 },
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.getByRole("button", { name: "Stop" }).waitFor();
    return page;
  }

  const composerText = (page: Page) => page.locator(".acpmux-composer-prompt .ProseMirror").innerText();

  describe("queue and steer while a turn runs", () => {
    test("Enter sends now without a queue flag: acpmux stops the turn", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("stop and do this instead");
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
      );
      expect({
        meta: prompts.map((p) => ({ queue: p._meta?.acpmux?.queue, steer: p._meta?.acpmux?.steer })),
        queued: await page.locator(".acpmux-queued").count(),
      }).toEqual({ meta: [{ queue: undefined, steer: undefined }], queued: 0 });
      await page.close();
    });

    test("⌥Enter queues each prompt behind the turn and frees the composer for the next", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("first follow-up");
      // The prompt stays in the composer until the host takes it (Composer.tsx), which can land
      // a moment after its queue row draws.
      const emptied = () =>
        page.waitForFunction(
          () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
        );
      await page.keyboard.press("Alt+Enter");
      await page.locator(".acpmux-queued", { hasText: "first follow-up" }).waitFor();
      await emptied();
      await page.keyboard.type("second follow-up");
      await page.keyboard.press("Alt+Enter");
      await page.locator(".acpmux-queued", { hasText: "second follow-up" }).waitFor();
      await emptied();
      expect({
        rows: await page.locator(".acpmux-queued").count(),
        composer: (await composerText(page)).trim(),
        steers: prompts.filter((p) => p._meta?.acpmux?.steer).length,
        queued: prompts.filter((p) => p._meta?.acpmux?.queue === true).length,
        sent: prompts.length,
      }).toEqual({ rows: 2, composer: "", steers: 0, queued: 2, sent: 2 });
      await page.close();
    });

    test("a prompt sent behind the turn never draws as a transcript bubble before its queue row", async () => {
      const page = await openChat();
      // Every bubble the transcript draws with the prompt's text, frame by frame.
      await page.evaluate(() => {
        const seen: string[] = [];
        (window as unknown as { bubbles: string[] }).bubbles = seen;
        const look = () => {
          for (const row of document.querySelectorAll<HTMLElement>("[data-row-id]"))
            if (row.innerText.includes("queued a beat late")) seen.push(row.dataset.rowId ?? "");
          requestAnimationFrame(look);
        };
        look();
      });
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("queued a beat late");
      await page.keyboard.press("Alt+Enter");
      await page.locator(".acpmux-queued", { hasText: "queued a beat late" }).waitFor();
      await page.waitForTimeout(600);
      expect(await page.locator(".acpmux-queued", { hasText: "queued a beat late" }).count()).toBe(1);
      expect(await page.evaluate(() => (window as unknown as { bubbles: string[] }).bubbles)).toEqual([]);
      await page.close();
    });

    test("Enter steers an agent that steers; ⌘Enter stops its turn instead", async () => {
      summary.steering = true;
      try {
        const page = await openChat();
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("look at the failing test first");
        await page.keyboard.press("Enter");
        await page.waitForFunction(
          () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
        );
        await page.keyboard.type("stop and rebase");
        await page.keyboard.press("Meta+Enter");
        await page.waitForFunction(
          () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
        );
        expect(prompts.map((p) => ({ steer: p._meta?.acpmux?.steer, queue: p._meta?.acpmux?.queue }))).toEqual([
          { steer: true, queue: undefined },
          { steer: undefined, queue: undefined },
        ]);
        await page.close();
      } finally {
        summary.steering = false;
      }
    });

    test("the Interrupt and send button stops a turn its agent cannot steer and sends now", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("use the new tokenizer");
      const button = page.getByRole("button", { name: "Interrupt and send" });
      await button.waitFor();
      await button.click();
      await page.waitForFunction(
        () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
      );
      expect({
        meta: prompts.map(
          (p) =>
            p._meta?.acpmux && {
              steer: p._meta.acpmux.steer,
              interrupt: p._meta.acpmux.interrupt,
            },
        ),
        queued: await page.locator(".acpmux-queued").count(),
      }).toEqual({ meta: [{ steer: true, interrupt: true }], queued: 0 });
      await page.close();
    });

    test("a queued prompt refused when its turn comes is back in the transcript, with Retry", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("refused at its turn");
      await page.keyboard.press("Alt+Enter");
      const failed = page.locator(".cv-user__status--failed", { hasText: "the chat's mode changed" });
      await failed.waitFor();
      expect(await failed.getByRole("button", { name: "Retry" }).count()).toBe(1);
      await page.close();
    });

    test("acpmux's end of a turn whose agent ignored Stop says so", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      const deadline = Date.now() + 5_000;
      while (cancels.length === 0 && Date.now() < deadline) await page.waitForTimeout(50);
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_result", { status: "cancelled", stopReason: "cancelled", turnId: "turn-1", cancelForced: true });
      await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor({ timeout: 5_000 });
      await page.close();
    });

    test("a turn still open a few seconds after Stop stops showing as working, and says so", async () => {
      const page = await openChat();
      // This acpmux never ends the turn (one without the forced end).
      await page.getByRole("button", { name: "Stop" }).click();
      await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor({ timeout: 10_000 });
      expect(await page.getByRole("button", { name: "Stop" }).count()).toBe(0);
      await page.close();
    });

    test("a Stop the agent answered leaves the next turn alone", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      const deadline = Date.now() + 5_000;
      while (cancels.length === 0 && Date.now() < deadline) await page.waitForTimeout(50);
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_result", { status: "cancelled", stopReason: "cancelled", turnId: "turn-1" });
      // The next prompt's turn starts inside Stop's grace and is still running after it.
      record("turn_started", { turnId: "turn-2" });
      await page.waitForTimeout(6_000);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      expect(await page.getByRole("button", { name: "Stop" }).count()).toBe(1);
      await page.close();
    });

    test("a turn that starts after Stop is never judged by that Stop", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      const deadline = Date.now() + 5_000;
      while (cancels.length === 0 && Date.now() < deadline) await page.waitForTimeout(50);
      // The stopped turn had already ended (the button was a frame stale): no turn_end follows,
      // and the next prompt's turn starts inside Stop's grace.
      record("turn_started", { turnId: "turn-2" });
      await page.waitForTimeout(6_000);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      expect(await page.getByRole("button", { name: "Stop" }).count()).toBe(1);
      await page.close();
    });

    test("a transcript rebuild inside Stop's grace does not cancel it", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      const deadline = Date.now() + 5_000;
      while (cancels.length === 0 && Date.now() < deadline) await page.waitForTimeout(50);
      // The replay passes the stopped turn's own turn_started again; it is not a new turn.
      await lag(page);
      await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor({ timeout: 10_000 });
      expect(await page.getByRole("button", { name: "Stop" }).count()).toBe(0);
      await page.close();
    });

    test("a turn Stop gave up on stays not working after a transcript rebuild", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor({ timeout: 10_000 });
      await lag(page);
      expect(await page.getByRole("button", { name: "Stop" }).count()).toBe(0);
      await page.close();
    });

    test("/permissions is not sent to Claude: the composer keeps it and names the access menu", async () => {
      const page = await openChat();
      const before = prompts.length;
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("/permissions");
      // The slash menu takes the first Enter when it is open.
      await page.keyboard.press("Escape");
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-attachment-note", { hasText: "access menu" }).waitFor({ timeout: 5_000 });
      await page.waitForTimeout(300);
      expect(prompts.length).toBe(before);
      expect((await composerText(page)).trim()).toBe("/permissions");
      await page.close();
    });

    test("a Claude Code variant's chat keeps /permissions in the composer too", async () => {
      summary.harness = "claude-sr";
      try {
        const page = await openChat();
        const before = prompts.length;
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("/permissions");
        await page.keyboard.press("Escape");
        await page.keyboard.press("Enter");
        await page.locator(".acpmux-attachment-note", { hasText: "access menu" }).waitFor({ timeout: 5_000 });
        expect(prompts.length).toBe(before);
        await page.close();
      } finally {
        summary.harness = "claude";
      }
    });

    test("Esc on an empty composer stops the turn", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      // The send guard ignores a stop right after a send; nothing was sent here.
      await page.keyboard.press("Escape");
      const deadline = Date.now() + 5_000;
      while (cancels.length === 0 && Date.now() < deadline) await page.waitForTimeout(50);
      expect(cancels.map((c) => c.sessionId)).toEqual([SESSION]);
      await page.close();
    });
  });
});
