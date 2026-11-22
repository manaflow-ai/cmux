// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A click on the composer of a busy chat puts the caret there and the keys that follow land in it (Leo, 2026-11-22:
// "for some reason i cant click into the composer of the gui chat to focus on it rn. it's claude-coord old", #49788).
// His chat was working (a turn running for minutes, its records still streaming) with a subagent running. Each case
// runs the real pane in Chromium against a stand-in acpmux that streams records while the person clicks:
// - the agent runs;
// - the agent runs with a subagent active (the running tray shows above the composer);
// - the same, after a switch away and back (the page goes hidden, then visible, as a workspace switch does).
// What sits at the click's point must be the composer's field (nothing over it takes the click), the field must have
// the focus after the click, and typed text must land in it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("composer-click-focus-browser.test.ts", async () => {
  setDefaultTimeout(280_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const SESSION = "0190a000-0000-7000-8000-0000000000c1";
  const SUBAGENT = `${SESSION}/toolu_helper`;
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: any };
  type Step = [dir: string, kind: string, msg: any];
  const base = 1_794_780_000_000;
  const update = (body: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: SESSION, update: body, ...(meta && { _meta: { acpmux: meta } }) },
  });
  const say = (text: string, segment: string): Step => [
    "in",
    "agent_message_chunk",
    update(
      { sessionUpdate: "agent_message_chunk", messageId: `msg-${segment}`, content: { type: "text", text } },
      { segment },
    ),
  ];
  const started = (id: string, meta?: Record<string, unknown>): Step => [
    "in",
    "tool_call",
    update(
      { sessionUpdate: "tool_call", toolCallId: id, title: `rg ${id}`, kind: "search", status: "in_progress" },
      meta,
    ),
  ];
  const done = (id: string, meta?: Record<string, unknown>): Step => [
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
  ];
  const prompt = (text: string, turnId: string): Step[] => [
    ["mux", "user_message", { text, turnId, promptId: `p-${turnId}`, _meta: { origin: { actor: "person" } } }],
    ["mux", "turn_started", { turnId, promptId: `p-${turnId}` }],
  ];
  const ended = (turnId: string): Step[] => [
    ["mux", "turn_end", { turnId, stopReason: "end_turn" }],
    ["mux", "turn_result", { turnId, status: "completed" }],
  ];
  const subagent: Step[] = [
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned", name: "Helper", background: true },
        {
          subagents: [
            { id: SUBAGENT, parent: null, name: "Helper", kind: "general-purpose", state: "running", background: true },
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
    started("helper-grep", { subagent: SUBAGENT }),
  ];

  // What the chat held before the pane opened: finished turns, then the turn that is still running.
  const history = (withSubagent: boolean): Step[] => {
    const steps: Step[] = [];
    for (let turn = 0; turn < 4; turn += 1)
      steps.push(
        ...prompt(`Earlier ask ${turn}`, `t-old-${turn}`),
        started(`old-${turn}`),
        done(`old-${turn}`),
        say(`Earlier answer ${turn}.`, `seg-old-${turn}`),
        ...ended(`t-old-${turn}`),
      );
    steps.push(...prompt("Land the queue", "t-live"), started("grep-1"), done("grep-1"));
    if (withSubagent) steps.push(...subagent);
    steps.push(started("grep-2"));
    return steps;
  };

  let events: Event[] = [];
  const toEvent = ([dir, kind, msg]: Step): Event => {
    const seq = events.length + 1;
    return { sessionId: SESSION, seq, at: base + seq * 400, dir, kind, msg };
  };
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Busy coordinator",
    harness: "claude",
    status: "running",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 5,
    createdAt: base,
    updatedAt: events.at(-1)?.at ?? base,
  });
  const page = (params: Record<string, any>, attach: boolean) => {
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const limit = params.limit === undefined ? Infinity : Math.max(1, Number(params.limit));
    const picked = events.filter((event) => event.seq > after && event.seq < before);
    const out = newest ? picked.slice(-limit) : picked.slice(0, limit);
    return { events: out, hasMore: out.length < picked.length };
  };
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        const last = events.at(-1)?.seq ?? 0;
        return { session: summary(), ...page(params, true), lastSeq: last, pageThrough: last, turnOpener: null };
      }
      case "_acpmux/events":
        return { ...page(params, false), lastSeq: events.at(-1)?.seq ?? 0 };
      default:
        return null;
    }
  }
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const sockets = new Set<any>();
  /// One more record of the running turn, streamed to the open pane as acpmux does.
  const stream = (step: Step) => {
    const event = toEvent(step);
    events.push(event);
    const note = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
    for (const ws of sockets) ws.send(note);
  };
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  const frames = (p: Page, count: number) =>
    p.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);
  const FIELD = "form.acpmux-composer .acpmux-md";

  /// The page hides and shows again, as a workspace switch away and back does to a tab's page.
  const switchAwayAndBack = async (p: Page) => {
    const set = (state: "hidden" | "visible") =>
      p.evaluate((next) => {
        Object.defineProperty(document, "visibilityState", { configurable: true, get: () => next });
        Object.defineProperty(document, "hidden", { configurable: true, get: () => next === "hidden" });
        if (next === "hidden") window.dispatchEvent(new Event("blur"));
        document.dispatchEvent(new Event("visibilitychange"));
        if (next === "visible") window.dispatchEvent(new Event("focus"));
      }, state);
    await set("hidden");
    stream(done("grep-2"));
    stream(started("grep-3"));
    await frames(p, 5);
    await set("visible");
    await frames(p, 10);
  };

  const cases = [
    { name: "the agent runs", subagent: false, switched: false },
    { name: "the agent runs with a subagent active", subagent: true, switched: false },
    { name: "a subagent is active, after a switch away and back", subagent: true, switched: true },
  ];
  describe("a click on a busy chat's composer focuses it", () => {
    for (const scenario of cases)
      test(scenario.name, async () => {
        events = [];
        for (const step of history(scenario.subagent)) events.push(toEvent(step));
        const p = await browser!.newPage({ viewport: { width: 900, height: 900 } });
        const errors: string[] = [];
        p.on("pageerror", (error) => errors.push(String(error)));
        const consoleLines: string[] = [];
        p.on("console", (message) => consoleLines.push(`${message.type()}: ${message.text()}`.slice(0, 300)));
        try {
          await installPaintedFrames(p);
          await p.goto(url());
          try {
            await p.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
          } catch (error) {
            const body = await p.evaluate(() => document.body.innerText.slice(0, 600)).catch(() => "?");
            throw new Error(
              `no transcript row: ${String(error).split("\n")[0]}\npage: ${body}\nerrors: ${errors.join("\n")}\nconsole: ${consoleLines.slice(-30).join("\n")}`,
            );
          }
          await p.locator(FIELD).waitFor({ timeout: 60_000 });
          if (scenario.subagent) await p.locator(".acpmux-running-tray").waitFor({ timeout: 60_000 });
          await frames(p, 20);
          // Nothing has the focus before the click: the click itself must give it.
          await p.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
          if (scenario.switched) await switchAwayAndBack(p);
          // The agent keeps working as the person clicks.
          stream(say("Still checking the queue", "seg-live"));
          await frames(p, 2);
          const box = await p.locator(FIELD).boundingBox();
          expect(box, "the composer's field is laid out").not.toBeNull();
          const x = box!.x + box!.width / 2;
          const y = box!.y + box!.height / 2;
          const hit = await p.evaluate(
            ([px, py, field]) => {
              const at = document.elementFromPoint(px!, py!);
              return { inField: Boolean(at?.closest(field!)), at: at ? `${at.tagName}.${at.className}` : "nothing" };
            },
            [x, y, FIELD] as const,
          );
          expect(hit.inField, `the click's point is ${hit.at}, not the composer's field`).toBe(true);
          await p.mouse.click(x, y);
          stream(say(" and the runners", "seg-live"));
          await frames(p, 3);
          const focus = await p.evaluate((field) => {
            const active = document.activeElement;
            return {
              inField: Boolean(active?.closest(field)),
              active: active ? `${active.tagName}.${active.className}` : "none",
            };
          }, FIELD);
          expect(focus.inField, `after the click the focus is on ${focus.active}`).toBe(true);
          await p.keyboard.type("land it");
          await frames(p, 3);
          const text = await p.locator(FIELD).innerText();
          expect(text).toContain("land it");
          expect(errors, errors.join("\n")).toEqual([]);
        } finally {
          await p.close();
        }
      });
  });
});
