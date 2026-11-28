// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Every reply the agent delivered stays drawn with its Copy row, whatever came around it: a turn that ends
// on its reply after tool calls, a subagent and another agent's message mid-turn; a turn a notice opened;
// a turn the API refused (429) or failed (529, its error streamed as text); a turn whose stream dropped
// mid-reply; and the turns after all of those (Leo, 2026-11-15, ask-65b54490d2: "i feel like the gui
// recovery for when api errors or whatever happen is pretty s**t it just stops rendering messages";
// ask-ef59fa0eb0: "w*f is happening here?", every turn an empty "Worked for Ns"). Runs the real pane in
// Chromium and WebKit (the app's engine) against a stand-in acpmux that streams the records live.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-replies-survive-failures-browser.test.ts", async () => {
  setDefaultTimeout(580_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("replies survive failures", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const SESSION = "0190a000-0000-7000-8000-0000000000e5";
  const SUBAGENT = `${SESSION}/toolu_helper`;
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: any };
  type Step = [dir: string, kind: string, msg: any] | "drop";
  const base = 1_794_780_000_000;
  const update = (body: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: SESSION, update: body, ...(meta && { _meta: { acpmux: meta } }) },
  });
  let segments = 0;
  const say = (text: string, segment: string, meta: Record<string, unknown> = {}): Step => [
    "in",
    "agent_message_chunk",
    update(
      { sessionUpdate: "agent_message_chunk", messageId: `msg-${segment}`, content: { type: "text", text } },
      { segment, ...meta },
    ),
  ];
  const think = (text: string): Step => [
    "in",
    "agent_thought_chunk",
    update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
  ];
  const ran = (id: string, meta?: Record<string, unknown>): Step[] => [
    [
      "in",
      "tool_call",
      update(
        { sessionUpdate: "tool_call", toolCallId: id, title: `rg ${id}`, kind: "search", status: "in_progress" },
        meta,
      ),
    ],
    [
      "in",
      "tool_call_update",
      update(
        {
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: `${id}: 3 matches` } }],
        },
        meta,
      ),
    ],
  ];
  const prompt = (text: string, turnId: string): Step[] => [
    ["mux", "user_message", { text, turnId, promptId: `p-${turnId}`, _meta: { origin: { actor: "person" } } }],
    ["mux", "turn_started", { turnId, promptId: `p-${turnId}` }],
  ];
  const ended = (turnId: string, fields: Record<string, unknown> = { status: "completed" }): Step[] => [
    ["mux", "turn_end", { turnId, stopReason: fields.status === "completed" ? "end_turn" : "error" }],
    ["mux", "turn_result", { turnId, ...fields }],
  ];
  const segment = () => `seg-${(segments += 1)}`;

  // What the chat held before the pane opened.
  const history: Step[] = [];
  for (let turn = 0; turn < 6; turn += 1) {
    const s = segment();
    history.push(
      ...prompt(`Earlier ask ${turn}`, `t-old-${turn}`),
      ...ran(`old-${turn}`),
      say(`Earlier answer ${turn}.`, s),
    );
    history.push(...ended(`t-old-${turn}`));
  }

  const FINAL = {
    work: "Work turn final: the check passed after the helper and the note.",
    notice: "Notice turn final: the background command failed, here is why.",
    partial: "Partial answer before the limit.",
    dropped: "Streaming before the drop, and after it it carried on.",
    later: "Later turn final: still rendering after every failure.",
  };
  const ERROR_429 = "API Error: 429 rate_limit_error: This request would exceed your rate limit.";
  /// A failed turn's way on: its card's Retry or Continue.
  const WAY_ON = /\b(retry|continue)\b/i;
  const ERROR_529 = "API Error: 529 overloaded_error: Overloaded";
  const live: Step[] = [];
  {
    // A turn that ends on its reply after tool calls, a subagent, thinking, and another agent's message.
    const note = segment();
    const final = segment();
    live.push(...prompt("Check the build and tell me", "t-work"));
    live.push(think("Looking at the build first."), ...ran("grep-1"), say("Before the check, one note.", note));
    live.push(
      [
        "in",
        "subagent_spawned",
        update(
          { sessionUpdate: "subagent_spawned", name: "Helper", background: true },
          {
            subagents: [
              {
                id: SUBAGENT,
                parent: null,
                name: "Helper",
                kind: "general-purpose",
                state: "running",
                background: true,
              },
            ],
          },
        ),
      ],
      [
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: "toolu_helper",
          title: "Agent: Helper",
          kind: "think",
          status: "in_progress",
          rawInput: { description: "Helper", prompt: "Look", run_in_background: true },
        }),
      ],
      ...ran("helper-grep", { subagent: SUBAGENT }),
    );
    live.push(...ran("grep-2"));
    live.push([
      "mux",
      "user_message",
      {
        text: "[cmux agent message] from reviewer (acp:reviewer)\n---\nThe retry loop is done.\n--- end of message m-1 ---",
        turnId: "t-work",
        promptId: "p-in-1",
        steer: true,
        _meta: { provenance: { kind: "agent_message", from: "acp:reviewer", to: `acp:${SESSION}`, msgId: "m-1" } },
      },
    ]);
    live.push(["mux", "steer_read", { promptId: "p-in-1", turnId: "t-work" }]);
    // The reply streams in pieces with the helper's records between them, under one segment.
    live.push(say("Work turn final: the check ", final));
    live.push(...ran("helper-grep-2", { subagent: SUBAGENT }));
    live.push(say("passed after the helper and the note.", final));
    live.push(...ended("t-work"));
  }
  {
    // A turn a notice opened (a background command finished).
    const final = segment();
    live.push(
      [
        "mux",
        "user_message",
        {
          text: "[notice from acpmux · WARN] Background command finished: land.sh (exit 1)",
          turnId: "t-notice",
          promptId: "bg-done-1",
          client: "acpmux",
          _meta: {
            provenance: {
              kind: "notice",
              from: "fromAgent",
              fromName: "acpmux",
              bgTaskId: "bg-1",
              notice: { sender: "acpmux", severity: "warn", title: "Background command finished: land.sh (exit 1)" },
              to: SESSION,
            },
          },
        },
      ],
      ["mux", "turn_started", { turnId: "t-notice", promptId: "bg-done-1" }],
      ...ran("log-1"),
      say(FINAL.notice, final),
      ...ended("t-notice"),
    );
  }
  {
    // The API refuses the request mid-reply: what streamed stays, the error and its Retry show.
    live.push(...prompt("Summarize the logs", "t-429"), say(FINAL.partial, segment()));
    live.push(...ended("t-429", { status: "failed", errorText: ERROR_429, errorCode: 429, errorSource: "agent" }));
  }
  {
    // The API fails and the harness streams the error as its message (acpmux `errorChunkSeqs`).
    live.push(...prompt("Try again", "t-529"), say(ERROR_529, segment()));
    live.push(
      ...ended("t-529", {
        status: "failed",
        errorText: ERROR_529,
        errorCode: 529,
        errorSource: "agent",
        errorChunkSeqs: "LAST_CHUNK",
      }),
    );
  }
  {
    // The pane's connection drops mid-reply; the rest arrives after it reconnects.
    const final = segment();
    live.push(...prompt("Keep going", "t-drop"), say("Streaming before the drop, ", final), "drop");
    live.push(say("and after it it carried on.", final), ...ended("t-drop"));
  }
  {
    live.push(
      ...prompt("Anything else?", "t-later"),
      ...ran("grep-3"),
      say(FINAL.later, segment()),
      ...ended("t-later"),
    );
  }

  let events: Event[] = [];
  let status = "idle";
  const toEvent = (step: Exclude<Step, "drop">): Event => {
    const seq = events.length + 1;
    const [dir, kind, msg] = step;
    if (msg?.errorChunkSeqs === "LAST_CHUNK") {
      const chunk = [...events].reverse().find((event) => event.kind === "agent_message_chunk")!;
      msg.errorChunkSeqs = [chunk.seq];
    }
    return { sessionId: SESSION, seq, at: base + seq * 400, dir, kind, msg };
  };
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Failures",
    harness: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 12,
    createdAt: base,
    updatedAt: events.at(-1)?.at ?? base,
  });
  const page = (params: Record<string, any>, attach: boolean) => {
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const limit = params.limit === undefined ? Infinity : Math.max(1, Number(params.limit));
    const out: Event[] = [];
    let hasMore = false;
    const take = (event: Event) => {
      if (event.seq <= after || event.seq >= before) return true;
      if (out.length >= limit) return !(hasMore = true);
      out.push(event);
      return true;
    };
    if (newest) {
      for (let i = events.length - 1; i >= 0 && take(events[i]!); i -= 1);
      out.reverse();
    } else for (let i = 0; i < events.length && take(events[i]!); i += 1);
    return { events: out, hasMore };
  };
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        const p = page(params, true);
        const last = events.at(-1)?.seq ?? 0;
        return { session: summary(), ...p, lastSeq: last, pageThrough: last, turnOpener: null };
      }
      case "_acpmux/events":
        return { ...page(params, false), lastSeq: events.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  }
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const sockets = new Set<any>();
  let attaches = 0;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
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
          if (message.method === "_acpmux/attach") attaches += 1;
          if (message.id === undefined) return;
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
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
  });
  afterAll(async () => {
    await vite?.close();
    await daemon?.stop(true);
  });
  const frames = (p: Page, count: number) =>
    p.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);
  /// The drawn rows, in order: id, text, and the labels of their buttons.
  const drawnRows = (p: Page) =>
    p.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>(".acpmux-scroll article.acpmux-row[data-row-id]")]
        .filter((node) => node.getBoundingClientRect().height > 0)
        .map((node) => ({
          id: node.dataset.rowId!,
          text: (node.textContent ?? "").replace(/\s+/g, " "),
          buttons: [...node.querySelectorAll("button")].map((button) =>
            `${button.getAttribute("aria-label") ?? ""} ${button.textContent ?? ""}`.trim(),
          ),
        })),
    );
  const toBottom = (p: Page) =>
    p.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = scroller.scrollHeight;
    });

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [engine, type] of engines)
    for (const scrolledUp of [false, true])
      test(`${engine}: every delivered reply keeps its Copy row through failures (scrolled up: ${scrolledUp})`, async () => {
        let browser: Browser;
        try {
          browser = await type.launch({ headless: true });
        } catch (error) {
          if (engine === "webkit" && !process.env.CI) return;
          throw error;
        }
        events = [];
        status = "idle";
        for (const step of history) events.push(toEvent(step as Exclude<Step, "drop">));
        const p = await browser.newPage({ viewport: { width: 1000, height: 2600 } });
        const errors: string[] = [];
        p.on("pageerror", (error) => errors.push(String(error)));
        try {
          await installPaintedFrames(p);
          await p.goto(url());
          await p.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
          await frames(p, 20);
          if (scrolledUp) {
            await p.mouse.move(500, 800);
            await p.mouse.wheel(0, -400);
            await frames(p, 10);
          }
          const attachedBefore = attaches;
          const wayOn: string[] = [];
          const gone = new Set<unknown>();
          for (const step of live) {
            if (step === "drop") {
              // The pane's link drops: what comes before it reconnects reaches it only by its read after
              // the reconnect; once back, records stream to it again, as from acpmux.
              for (const ws of sockets) {
                gone.add(ws);
                ws.close();
              }
              continue;
            }
            const event = toEvent(step);
            events.push(event);
            if (event.kind === "turn_started") status = "running";
            if (event.kind === "turn_result") status = "idle";
            const note = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
            for (const ws of sockets) if (!gone.has(ws)) ws.send(note);
            await frames(p, 1);
            // A failed turn that is the chat's last offers its way on (Retry or Continue) where it failed.
            if (event.kind === "turn_result" && event.msg.status === "failed") {
              const turnId = String(event.msg.turnId);
              let failure: Awaited<ReturnType<typeof drawnRows>>[number] | undefined;
              for (let tries = 0; tries < 60 && !failure?.buttons.some((label) => WAY_ON.test(label)); tries += 1) {
                if (scrolledUp && tries === 10) await toBottom(p);
                await frames(p, 2);
                failure = (await drawnRows(p)).find((row) => row.id === `summary-${turnId}`);
              }
              wayOn.push(`${turnId}: [${failure?.buttons.join("|") ?? "no row"}] ${failure?.text.slice(0, 80) ?? ""}`);
            }
          }
          // The pane reconnects on its own and reads what it missed.
          const deadline = Date.now() + 60_000;
          while (Date.now() < deadline && attaches === attachedBefore) await frames(p, 5);
          expect(attaches).toBeGreaterThan(attachedBefore);
          let rows = await drawnRows(p);
          const has = (text: string) => rows.some((row) => row.text.includes(text));
          for (let tries = 0; tries < 200 && !(has(FINAL.dropped) && has(FINAL.later)); tries += 1) {
            if (scrolledUp && tries === 20) await toBottom(p);
            await frames(p, 5);
            rows = await drawnRows(p);
          }
          await toBottom(p);
          await frames(p, 30);
          rows = await drawnRows(p);
          const report = rows.map((row) => `${row.id} [${row.buttons.join("|")}] ${row.text.slice(0, 80)}`).join("\n");
          // Each delivered reply is drawn whole, and the turn it ends has its Copy row after it.
          for (const text of [FINAL.work, FINAL.notice, FINAL.dropped, FINAL.later]) {
            const at = rows.findIndex((row) => row.id.startsWith("assistant-") && row.text.includes(text));
            expect(at, `${text}\n${report}`).toBeGreaterThanOrEqual(0);
            // The very next row is its turn's footer: a later turn's Copy row does not count for it.
            const footer = rows[at + 1]?.id.startsWith("summary-") ? rows[at + 1] : undefined;
            expect(
              footer?.buttons.some((label) => /copy/i.test(label)),
              `${text} copy row\n${report}`,
            ).toBe(true);
          }
          // What streamed before the API refused shows; the failures say why, with a Retry.
          expect(has(FINAL.partial), report).toBe(true);
          for (const code of ["429", "529"]) {
            const failure = rows.find((row) => row.text.includes(`API Error: ${code}`));
            expect(failure, `${code}\n${report}`).toBeDefined();
          }
          console.log(`way on: ${wayOn.join("\n")}`);
          for (const line of wayOn) expect(WAY_ON.test(line.split("]")[0]!), line).toBe(true);
          expect(errors, errors.join("\n")).toEqual([]);
        } finally {
          await p.close();
          await browser.close();
        }
      });
});
