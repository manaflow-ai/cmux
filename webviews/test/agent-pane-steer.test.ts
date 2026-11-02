// Queue and steer while a turn runs, in the real agent pane (cx-xtg0.3). The page is the pane's dev
// entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a WebSocket to a
// stand-in acpmux daemon whose one chat has a turn running, and which answers prompts as acpmux
// does: a plain prompt waits behind the turn (`queued`), a steer goes into it (`user_message`).
//
// - Enter queues: the queue row shows the prompt and the composer is free for the next one. The
//   prompt shows there from the send on, never first as a transcript bubble.
// - Nothing sent stops the turn (Leo 2026-10-20): to an agent that cannot steer, ⌘Enter queues the
//   prompt too, with no steer control and no `_meta.acpmux.interrupt`.
// - Esc stops the turn on a second press (escapeStop.ts): the first arms Stop (same glyph, no text,
//   named "Press Esc again to stop"), and typing, a click, focus moving or the window ending puts Stop back. An Esc nothing else took
//   (focus outside the composer, as in a question card) counts too; with no turn, Esc does nothing.
// - Stop says Stopping until acpmux ends the turn. Only its forced-end event says the agent
//   ignored cancellation; elapsed time in this page never declares the turn ended.
// - A slash command that runs only in Claude Code's terminal (`/permissions`) is not sent: the
//   composer keeps it and names the control to use.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
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
    // Claude Code's commands, as acpmux keeps the newest list: a skill (/loop) among them.
    availableCommands: {
      sessionUpdate: "available_commands_update",
      availableCommands: [{ name: "loop", description: "Run a prompt or slash command on a recurring interval" }],
    },
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
  /// Set while a test opens the chat with its turn already over (no Stop to arm).
  let idleChat = false;
  const idleSummary = () => ({ ...summary, status: "idle", turn: undefined });
  const finished = [
    {
      sessionId: SESSION,
      at: Date.now(),
      dir: "mux",
      kind: "turn_end",
      msg: { stopReason: "end_turn", turnId: "turn-1" },
    },
    {
      sessionId: SESSION,
      at: Date.now(),
      dir: "mux",
      kind: "turn_result",
      msg: { status: "completed", turnId: "turn-1" },
    },
  ];
  let seq = opening.length;
  const prompts: Record<string, any>[] = [];
  const cancels: Record<string, any>[] = [];
  /// `_acpmux/events` reads: a lag resync's refetch, which rebuilds the transcript.
  let eventReads = 0;
  /// Set once the late `queued` record (`queued a beat late`) went out.
  let lateQueued = false;
  /// `_acpmux/attach` requests: the page reads the chat again on each connection.
  let attaches = 0;

  /// The waits on what the daemon heard: each message it takes, and each record it sends late, wakes them.
  const waiting = new Set<() => void>();
  const heard = () => {
    for (const wake of waiting) wake();
  };
  /// Resolves once `condition` holds, checked as the daemon hears each message; fails naming `what`.
  const until = (condition: () => boolean, what: string, timeout = 5_000) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!condition()) return;
        waiting.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        waiting.delete(check);
        reject(new Error(`the daemon never saw ${what} within ${timeout} ms`));
      }, timeout);
      waiting.add(check);
      check();
    });

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [idleChat ? idleSummary() : summary] };
      case "_acpmux/attach":
        attaches += 1;
        if (idleChat) {
          const events = [...opening, ...finished.map((each, index) => ({ ...each, seq: opening.length + index + 1 }))];
          return { session: idleSummary(), lastSeq: events.length, events };
        }
        return { session: summary, lastSeq: opening.length, events: opening };
      case "_acpmux/events":
        eventReads += 1;
        return { events: [], hasMore: false, lastSeq: seq };
      default:
        return null;
    }
  }

  /// acpmux's answer to a prompt while the turn runs: no reply until its turn, only an event.
  function prompted(ws: { send(data: string): void; close(): void }, params: Record<string, any>, id?: number): void {
    prompts.push(params);
    const meta = params._meta?.acpmux ?? {};
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    const msg = meta.steer
      ? { text, promptId: meta.promptId, turnId: "turn-1", steer: true }
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
      kind: meta.steer ? "user_message" : "queued",
      msg,
    };
    const deliver = () => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    // acpmux's `queued` record can come a beat after the send (130 ms on cosmic-gray, 2026-10-13).
    if (text === "queued a beat late")
      setTimeout(() => {
        deliver();
        lateQueued = true;
        heard();
      }, 400);
    else deliver();
    // acpmux checks a queued prompt again when its turn comes (`check_dispatch`) and may refuse it.
    if (text === "refused at its turn")
      setTimeout(() => {
        const error = { code: -32602, message: "web_control.refused: the chat's mode changed" };
        ws.send(JSON.stringify({ jsonrpc: "2.0", id, error }));
      }, 300);
    // A steer acpmux took (its echo is out) whose request ends in an error later: the agent's, or
    // the connection's when it drops while the steer waits to be read.
    if (text === "steer then the agent errs")
      ws.send(JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32603, message: "agent exited" } }));
    if (text === "steer then the connection drops") ws.close();
  }

  let socket: { send(data: string): void } | undefined;
  /// An acpmux record, as the attached page gets it.
  const record = (kind: string, msg: Record<string, unknown>, hostSeq?: number) =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: SESSION, seq: ++seq, at: Date.now(), dir: "mux", kind, msg, hostSeq },
      }),
    );
  const recordInbound = (kind: string, msg: Record<string, unknown>) =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: SESSION, seq: ++seq, at: Date.now(), dir: "in", kind, msg },
      }),
    );

  let notes = 0;
  /// Returns once the page has drawn a record sent now, so it has handled and drawn everything
  /// before it. The record is a failover note: the transcript draws it, and it is nothing to the
  /// turn or to Stop.
  async function drawn(page: Page): Promise<void> {
    const to = `marker-${++notes}`;
    record("failover", { from: "claude", to });
    await page.getByText(`Continued on ${to}`).waitFor({ timeout: 5_000 });
  }

  /// acpmux dropped events for the page: it refetches and replays the whole transcript. Returns once
  /// the rebuild is drawn, and anything the page sent before the refetch (a cancel, a prompt) has
  /// reached the daemon.
  async function lag(page: Page): Promise<void> {
    const before = eventReads;
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/lagged", params: { sessionIds: [SESSION] } }));
    await until(() => eventReads > before, "the lag resync's refetch");
    await drawn(page);
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
          if (message.method === "session/prompt") {
            prompted(ws, message.params ?? {}, message.id);
            return heard();
          }
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
          heard();
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

  /// The chat with its turn running; `clock` puts the page's timers on Playwright's clock, so a test
  /// can move past the old Stop deadline without waiting it out.
  async function openChat({ clock = false } = {}): Promise<Page> {
    prompts.length = 0;
    cancels.length = 0;
    lateQueued = false;
    const page = await browser!.newPage({
      viewport: { width: 900, height: 760 },
    });
    await installPaintedFrames(page);
    if (clock) await page.clock.install();
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.locator(".acpmux-composer-prompt").waitFor();
    await page.getByRole("button", { name: "Stop" }).waitFor();
    return page;
  }

  const composerText = (page: Page) => page.locator(".acpmux-composer-prompt .ProseMirror").innerText();

  describe("queue and steer while a turn runs", () => {
    test("Enter queues each prompt behind the turn and frees the composer for the next", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("first follow-up");
      // The prompt stays in the composer until the host takes it (Composer.tsx), which can land
      // a moment after its queue row draws.
      const emptied = () =>
        page.waitForFunction(
          () => document.querySelector(".acpmux-composer-prompt .ProseMirror")?.textContent?.trim() === "",
        );
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-queued", { hasText: "first follow-up" }).waitFor();
      await emptied();
      await page.keyboard.type("second follow-up");
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-queued", { hasText: "second follow-up" }).waitFor();
      await emptied();
      expect({
        rows: await page.locator(".acpmux-queued").count(),
        composer: (await composerText(page)).trim(),
        steers: prompts.filter((p) => p._meta?.acpmux?.steer).length,
        sent: prompts.length,
      }).toEqual({ rows: 2, composer: "", steers: 0, sent: 2 });
      await page.close();
    });

    test("a prompt sent behind the turn never draws as a transcript bubble before its queue row", async () => {
      const page = await openChat();
      // Every bubble the transcript draws with the prompt's text, painted frame by painted frame.
      await page.evaluate(() => {
        const seen: string[] = [];
        (window as unknown as { bubbles: string[] }).bubbles = seen;
        window.cmuxAfterPaint(() => {
          for (const row of document.querySelectorAll<HTMLElement>("[data-row-id]"))
            if (row.innerText.includes("queued a beat late")) seen.push(row.dataset.rowId ?? "");
        });
      });
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("queued a beat late");
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-queued", { hasText: "queued a beat late" }).waitFor();
      // acpmux's late `queued` record went out, and the page has drawn what came after it.
      await until(() => lateQueued, "the late queued record go out");
      await lag(page);
      expect(await page.locator(".acpmux-queued", { hasText: "queued a beat late" }).count()).toBe(1);
      expect(await page.evaluate(() => (window as unknown as { bubbles: string[] }).bubbles)).toEqual([]);
      await page.close();
    });

    test("⌘Enter queues to an agent that cannot steer and never stops the turn", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("use the new tokenizer");
      await page.keyboard.press("Meta+Enter");
      await page.locator(".acpmux-queued", { hasText: "use the new tokenizer" }).waitFor();
      expect({
        meta: prompts.map(
          (p) =>
            p._meta?.acpmux && {
              steer: p._meta.acpmux.steer,
              interrupt: p._meta.acpmux.interrupt,
            },
        ),
        steerControl: await page.locator(".acpmux-steer-now").count(),
        cancels: cancels.length,
      }).toEqual({ meta: [{ steer: undefined, interrupt: undefined }], steerControl: 0, cancels: 0 });
      await page.close();
    });

    test("a queued prompt refused when its turn comes is back in the transcript, with Retry", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.type("refused at its turn");
      await page.keyboard.press("Enter");
      const failed = page.locator(".cv-user__status--failed", { hasText: "the chat's mode changed" });
      await failed.waitFor();
      expect(await failed.getByRole("button", { name: "Retry" }).count()).toBe(1);
      await page.close();
    });

    // A steer acpmux took is in the transcript: whatever ends its request later never puts it back
    // in the composer, where the next Enter would send it twice (2026-10-23).
    for (const text of ["steer then the agent errs", "steer then the connection drops"])
      test(`a steer acpmux took stays out of the composer: ${text}`, async () => {
        summary.steering = true;
        try {
          const page = await openChat();
          const before = attaches;
          await page.locator(".acpmux-composer-prompt").click();
          await page.keyboard.type(text);
          await page.keyboard.press("Enter");
          await page.locator("[data-row-id]", { hasText: text }).first().waitFor({ timeout: 5_000 });
          if (text.endsWith("drops")) await until(() => attaches > before, "the page read the chat again");
          // The page has drawn a refetch that came after the request ended.
          await lag(page);
          expect({
            steers: prompts.filter((p) => p._meta?.acpmux?.steer).length,
            composer: (await composerText(page)).trim(),
            failed: await page.locator(".cv-user__status--failed").count(),
          }).toEqual({ steers: 1, composer: "", failed: 0 });
          await page.close();
        } finally {
          summary.steering = false;
        }
      });

    // Claude Code holds a command until the command it runs ends, so a steered `/loop` sat as an
    // unread steer with Send now (Leo, 2026-10-31: "the commands don't work!"). It queues instead
    // and runs as its own turn; text that only starts with a slash still steers.
    test("Enter queues one of the agent's slash commands even to an agent that steers", async () => {
      summary.steering = true;
      try {
        const page = await openChat();
        await page.locator(".acpmux-composer-prompt").click();
        await page.keyboard.type("/loop keep launching new dev builds");
        expect(await page.locator(".acpmux-steer-now").count()).toBe(0);
        await page.keyboard.press("Enter");
        await page.locator(".acpmux-queued", { hasText: "/loop keep launching new dev builds" }).waitFor();
        await page.keyboard.type("/tmp is full, clean it");
        await page.keyboard.press("Enter");
        await until(() => prompts.length === 2, "the second prompt");
        expect(prompts.map((p) => Boolean(p._meta?.acpmux?.steer))).toEqual([false, true]);
        await page.close();
      } finally {
        summary.steering = false;
      }
    });

    test("acpmux's end of a turn whose agent ignored Stop says so", async () => {
      const page = await openChat();
      recordInbound("compaction", {
        method: "session/update",
        params: { update: { sessionUpdate: "compaction", state: "running" } },
      });
      await page.locator('.cv-compaction[data-state="running"]').waitFor();
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      record("compaction_metadata_fenced", { sourceKind: "compaction" }, 40);
      await drawn(page);
      expect(await page.getByRole("button", { name: "Continue", exact: true }).count()).toBe(0);
      expect(await page.locator('.cv-compaction[data-state="running"]').count()).toBe(1);
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_result", { status: "cancelled", stopReason: "cancelled", turnId: "turn-1", cancelForced: true });
      record("status", { status: "idle" });
      await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor({ timeout: 5_000 });
      expect(await page.getByRole("button", { name: "Continue", exact: true }).count()).toBe(1);
      // The cancelled compaction can report its boundary after a new explicit prompt. It must not
      // revive the old row; a fresh running update still gets its own row.
      record("user_message", { text: "next prompt", promptId: "p-next", turnId: "turn-2" });
      record("turn_started", { promptId: "p-next", turnId: "turn-2" });
      recordInbound("compaction", {
        method: "session/update",
        params: { update: { sessionUpdate: "compaction", state: "completed" } },
      });
      await drawn(page);
      expect(await page.locator('.cv-compaction[data-state="completed"]').count()).toBe(0);
      recordInbound("compaction", {
        method: "session/update",
        params: { update: { sessionUpdate: "compaction", state: "running" } },
      });
      await page.locator('.cv-compaction[data-state="running"]').last().waitFor();
      const compactionRows = await page.locator(".cv-compaction").count();
      record("compaction_metadata_fenced", { sourceKind: "compaction_summary" }, 41);
      record("compaction_metadata_fenced", { sourceKind: "compaction" }, 42);
      await drawn(page);
      expect(await page.locator(".cv-compaction").count()).toBe(compactionRows);
      expect(await page.locator('.cv-compaction[data-state="running"]').count()).toBe(1);
      recordInbound("compaction", {
        method: "session/update",
        params: { update: { sessionUpdate: "compaction", state: "completed" } },
      });
      // Even after fresh running, these ambiguous boundaries could belong to the stopped turn.
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_end", { stopReason: "cancelled" });
      record("turn_result", { status: "cancelled" });
      await drawn(page);
      expect(await page.locator('.cv-compaction[data-state="completed"]').count()).toBe(0);
      expect(await page.locator('.cv-compaction[data-state="running"]').count()).toBe(1);
      record("turn_result", { status: "completed", turnId: "turn-2" });
      await drawn(page);
      expect(await page.locator('.cv-compaction[data-state="running"]').count()).toBe(0);
      recordInbound("compaction", {
        method: "session/update",
        params: { update: { sessionUpdate: "compaction", state: "completed" } },
      });
      await drawn(page);
      expect(await page.locator('.cv-compaction[data-state="completed"]').count()).toBe(0);
      await page.close();
    });

    test("Stopping stays visible past the old grace until the daemon ends the turn", async () => {
      const page = await openChat({ clock: true });
      // This acpmux never ends the turn (one without the forced end).
      await page.getByRole("button", { name: "Stop" }).click();
      await page.getByRole("button", { name: "Stopping…", exact: true }).waitFor();
      await page.clock.runFor(6_000);
      await drawn(page);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      expect(await page.getByRole("button", { name: "Stopping…", exact: true }).count()).toBe(1);
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      await drawn(page);
      expect(await page.getByRole("button", { name: "Stopping…", exact: true }).count()).toBe(0);
      await page.close();
    });

    test("a pending Stop leaves a distinct new turn working and able to send now", async () => {
      const page = await openChat({ clock: true });
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      await page.clock.runFor(6_000);
      await drawn(page);
      expect(await page.getByRole("button", { name: "Stop", exact: true }).count()).toBe(0);
      record("user_message", { text: "new work", turnId: "turn-2" });
      record("turn_started", { turnId: "turn-2" });
      await drawn(page);
      expect(await page.getByRole("button", { name: "Stop", exact: true }).count()).toBe(1);
      record("queued", { text: "send now", promptId: "p-now" });
      record("queue_order", { promptId: "p-now", next: true, order: ["p-now"] });
      record("turn_result", { status: "cancelled", turnId: "turn-2" });
      await drawn(page);
      // Send-now ended the current turn as a continuation, not as the older Stop.
      expect(await page.getByRole("button", { name: "Continue", exact: true }).count()).toBe(0);
      await page.close();
    });

    test("a Stop the agent answered leaves the next turn alone", async () => {
      const page = await openChat({ clock: true });
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_result", { status: "cancelled", stopReason: "cancelled", turnId: "turn-1" });
      // The next prompt's turn starts before the old Stop deadline and is still running after it.
      record("turn_started", { turnId: "turn-2" });
      await drawn(page);
      // Past the old five-second client deadline, then draw another record.
      await page.clock.runFor(6_000);
      await drawn(page);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      expect(await page.getByRole("button", { name: "Stop", exact: true }).count()).toBe(1);
      await page.close();
    });

    test("a turn that starts after Stop is never judged by that Stop", async () => {
      const page = await openChat({ clock: true });
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      // The stopped turn had already ended (the button was a frame stale): no turn_end follows,
      // and the next prompt's turn starts before the old Stop deadline.
      record("turn_started", { turnId: "turn-2" });
      await drawn(page);
      // Past the old five-second client deadline, then draw another record.
      await page.clock.runFor(6_000);
      await drawn(page);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      expect(await page.getByRole("button", { name: "Stop", exact: true }).count()).toBe(1);
      await page.close();
    });

    test("a transcript rebuild keeps Stopping until the stopped turn ends", async () => {
      const page = await openChat({ clock: true });
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      // The replay passes the stopped turn's own turn_started again; it is not a new turn.
      await lag(page);
      await page.clock.runFor(6_000);
      await drawn(page);
      expect(await page.getByRole("button", { name: "Stopping…", exact: true }).count()).toBe(1);
      expect(await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").count()).toBe(0);
      await page.close();
    });

    test("a turn the daemon forcibly ended stays stopped after a transcript rebuild", async () => {
      const page = await openChat();
      await page.getByRole("button", { name: "Stop" }).click();
      await until(() => cancels.length > 0, "Stop's session/cancel");
      record("turn_end", { stopReason: "cancelled", turnId: "turn-1" });
      record("turn_result", { status: "cancelled", turnId: "turn-1", cancelForced: true });
      summary.status = "idle";
      socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/session_changed", params: { session: summary } }));
      try {
        await page.getByText("The agent didn't answer Stop, so cmux ended its turn.").waitFor();
        await lag(page);
        expect(await page.getByRole("button", { name: "Stop", exact: true }).count()).toBe(0);
        expect(await page.getByRole("button", { name: "Stopping…", exact: true }).count()).toBe(0);
      } finally {
        summary.status = "running";
        await page.close();
      }
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
      // A prompt the page sent would reach the daemon before the refetch.
      await lag(page);
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

    test("one Esc on an empty composer only says to press it again; the second stops the turn", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      // The send guard ignores a stop right after a send; nothing was sent here.
      await page.keyboard.press("Escape");
      await page.locator(".acpmux-md-placeholder", { hasText: "Press Esc again to stop" }).waitFor({ timeout: 2_000 });
      // The second press must land inside the 1.6 s window, so no long wait here.
      expect(cancels.length).toBe(0);
      await page.keyboard.press("Escape");
      await until(() => cancels.length > 0, "Stop's session/cancel");
      // A second cancel would reach the daemon before the refetch.
      await lag(page);
      expect(cancels.map((c) => c.sessionId)).toEqual([SESSION]);
      await page.close();
    });

    test("two Esc presses far apart do not stop the turn, and the hint goes away", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("Escape");
      const hint = page.locator(".acpmux-md-placeholder", { hasText: "Press Esc again to stop" });
      await hint.waitFor({ timeout: 2_000 });
      // The placeholder goes back to its usual text once the window ends.
      await hint.waitFor({ state: "detached", timeout: 3_000 });
      await page.keyboard.press("Escape");
      // The late press only arms again, and no cancel went before the refetch.
      await hint.waitFor({ timeout: 2_000 });
      await lag(page);
      expect(cancels.length).toBe(0);
      await page.close();
    });

    const escHint = (page: Page) => page.getByRole("button", { name: "Press Esc again to stop" });
    const stopButton = (page: Page) => page.getByRole("button", { name: "Stop", exact: true });
    /// Arms the stop from the composer and waits for Stop to be named "Press Esc again to stop".
    async function arm(page: Page): Promise<void> {
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("Escape");
      await escHint(page).waitFor({ timeout: 1_000 });
    }

    test("the first Esc arms Stop (renamed, its glyph kept, no text), and the window ending puts Stop back", async () => {
      const page = await openChat();
      await arm(page);
      // The armed Stop is the same plain glyph, named "Press Esc again to stop" and cued by its color.
      expect(await escHint(page).getAttribute("data-escape-armed")).toBe("");
      expect(await escHint(page).locator("svg").count()).toBe(1);
      expect((await escHint(page).innerText()).trim()).toBe("");
      expect(await stopButton(page).count()).toBe(0);
      await stopButton(page).waitFor({ timeout: 3_000 });
      expect(await escHint(page).count()).toBe(0);
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("typing between the presses puts Stop back, and the next Esc only arms again", async () => {
      const page = await openChat();
      await arm(page);
      // A typed character shows Send; deleting it shows Stop again, unarmed.
      await page.keyboard.type("a");
      await page.keyboard.press("Backspace");
      // Well inside the window: only the typing can have disarmed it.
      await stopButton(page).waitFor({ timeout: 500 });
      await page.keyboard.press("Escape");
      // The next press only arms again, and no cancel went before the refetch.
      await escHint(page).waitFor({ timeout: 1_000 });
      await lag(page);
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("a key that types nothing between the presses puts Stop back too", async () => {
      const page = await openChat();
      await arm(page);
      await page.keyboard.press("ArrowLeft");
      await stopButton(page).waitFor({ timeout: 500 });
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("an Esc on another control (a header button) neither arms nor stops", async () => {
      // Rows, tooltips and the minimap act on Esc without claiming it: only the composer, a
      // question card and a page with nothing focused count it as a press.
      const page = await openChat();
      const focused = await page.evaluate(() => {
        const control = [...document.querySelectorAll<HTMLElement>("button")].find(
          (each) => !each.closest(".acpmux-composer") && each.offsetParent !== null,
        );
        control?.focus();
        return document.activeElement === control && control !== undefined;
      });
      expect(focused).toBe(true);
      await page.keyboard.press("Escape");
      // The page has drawn a refetch that came after the press: an armed stop would show by then.
      await lag(page);
      expect(await escHint(page).count()).toBe(0);
      await page.keyboard.press("Escape");
      await lag(page);
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("a click between the presses puts Stop back", async () => {
      const page = await openChat();
      await arm(page);
      // A click in the prompt, which already has focus: no focus moves.
      await page.locator(".acpmux-composer-prompt").click();
      await stopButton(page).waitFor({ timeout: 500 });
      await page.keyboard.press("Escape");
      // The next press only arms again, and no cancel went before the refetch.
      await escHint(page).waitFor({ timeout: 1_000 });
      await lag(page);
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("focus moving between the presses puts Stop back", async () => {
      const page = await openChat();
      await arm(page);
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await stopButton(page).waitFor({ timeout: 500 });
      expect(cancels.length).toBe(0);
      await page.close();
    });

    test("an Esc no other control takes, with focus outside the composer, counts as a press", async () => {
      // A question card leaves Esc to this double press: the key reaches the page, not the prompt.
      const page = await openChat();
      await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
      await page.keyboard.press("Escape");
      await escHint(page).waitFor({ timeout: 1_000 });
      expect(cancels.length).toBe(0);
      await page.keyboard.press("Escape");
      await until(() => cancels.length > 0, "Stop's session/cancel");
      // A second cancel would reach the daemon before the refetch.
      await lag(page);
      expect(cancels.map((c) => c.sessionId)).toEqual([SESSION]);
      await page.close();
    });

    test("with no turn running, Esc neither arms nor stops", async () => {
      idleChat = true;
      try {
        prompts.length = 0;
        cancels.length = 0;
        const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
        const { port } = vite!.httpServer!.address() as { port: number };
        const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
        await page.goto(
          `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`,
        );
        await page.locator(".acpmux-composer-prompt").click();
        // The finished chat has drawn: its prompt's bubble comes with the turn's end in one attach.
        // The empty draft draws no Send (Claude desktop's box: no Send until there is a draft,
        // Leo 2026-10-20), so the bubble, not Send, says the idle chat is in.
        await page.locator(".cv-user__bubble", { hasText: turn.prompt }).waitFor({ timeout: 5_000 });
        expect(await stopButton(page).count()).toBe(0);
        await page.keyboard.press("Escape");
        // The page has drawn a refetch that came after the press: an armed stop would show by then.
        await lag(page);
        expect(await escHint(page).count()).toBe(0);
        await page.keyboard.press("Escape");
        await lag(page);
        expect(await escHint(page).count()).toBe(0);
        expect(cancels.length).toBe(0);
        await page.close();
      } finally {
        idleChat = false;
      }
    });
  });
});
