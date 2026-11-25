// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// React #185 (Maximum update depth exceeded) in Leo's NIGHTLY, 2026-11-24 02:17Z to 02:22Z, each
// 0.5 to 3 s after the app's health monitor reloaded a hung page of a coordinator chat with 100+
// background subagents, its Background tasks tab open and a subagent drilled into (Leo, 2026-11-24:
// "oh and i previously had an "agent pane was not able to redraw" which idk if it's fixed here but").
// Each scenario is a fresh page load of a chat shaped like that one, in real Chromium on the pane's dev
// entry (dev React: the full message and a real stack), and fails printing every loop error in full.
// Green on this data (2026-11-24): it guards the shape; the pane's boundary now logs where a loop
// happens on the journal's first line (PaneBoundary.tsx), so the next hit in the app names it.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-update-loop-repro.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-update-loop-repro: skipping (run `bunx playwright install chromium`)");
    describe.skip("update loop repro", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const IDLE = "0190a000-0000-7000-8000-0000000000f1";
  const WORKING = "0190a000-0000-7000-8000-0000000000f2";
  const START = Date.UTC(2026, 10, 23, 9, 0, 0);
  const TURNS = 65;
  const PER_TURN = 2;
  const STEPS = 8;
  const RUNNING = 6;

  type Params = { sessionId: string; tag?: string; subagents?: unknown[] };
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (body: Record<string, unknown>, { sessionId, tag, subagents }: Params) => ({
    method: "session/update",
    params: {
      sessionId,
      update: body,
      ...((tag || subagents) && {
        _meta: { acpmux: { ...(tag && { subagent: tag }), ...(subagents && { subagents }) } },
      }),
    },
  });
  const paragraph = (turn: number, n: number) =>
    `Paragraph ${n} of turn ${turn}: the helpers reported back; the lane landed its change, CI is green on ` +
    `the head, and the next step waits on the review. Nothing else is blocked, and the fleet is idle.`;

  /// A coordinator chat: every turn starts background helpers, each running shell steps in its own
  /// session; the newest RUNNING helpers still run. `working`: the last turn has not ended.
  function chat(chatId: string, working: boolean) {
    const steps: Step[] = [];
    const own = (body: Record<string, unknown>, extra: Partial<Params> = {}) =>
      update(body, { sessionId: chatId, ...extra });
    const total = TURNS * PER_TURN;
    const helpers: { id: string; name: string; call: string }[] = [];
    for (let turn = 0; turn < TURNS; turn++) {
      steps.push(["mux", "user_message", { text: `Coordinate batch ${turn}` }], ["mux", "turn_started", {}]);
      for (let k = 0; k < PER_TURN; k++) {
        const index = turn * PER_TURN + k;
        const call = `agentcall${index}`;
        const id = `${chatId}/${call}`;
        const name = `Lane ${index}: fix the thing ${index}`;
        helpers.push({ id, name, call });
        const running = index >= total - RUNNING;
        steps.push(
          [
            "in",
            "subagent_spawned",
            own(
              { sessionUpdate: "subagent_spawned", name, background: true },
              {
                subagents: [{ id, parent: null, name, kind: "general-purpose", state: "running", background: true }],
              },
            ),
          ],
          [
            "in",
            "tool_call",
            own({
              sessionUpdate: "tool_call",
              toolCallId: call,
              title: `Agent: ${name}`,
              kind: "think",
              status: "in_progress",
              rawInput: { description: name, prompt: `Do task ${index}`, run_in_background: true },
            }),
          ],
          ["in", "tool_call_update", own({ sessionUpdate: "tool_call_update", toolCallId: call, status: "completed" })],
        );
        for (let s = 0; s < STEPS; s++) {
          const tool = `${call}-sh${s}`;
          const command = `rg -n "pattern${s}" src/lane${index} | head -${20 + s}`;
          const sub = { sessionId: id, tag: id };
          steps.push(
            [
              "in",
              "tool_call",
              update(
                {
                  sessionUpdate: "tool_call",
                  toolCallId: tool,
                  title: command,
                  kind: "execute",
                  status: "in_progress",
                  rawInput: { command },
                },
                sub,
              ),
            ],
            [
              "in",
              "tool_call_update",
              update(
                {
                  sessionUpdate: "tool_call_update",
                  toolCallId: tool,
                  status: "completed",
                  content: [{ type: "content", content: { type: "text", text: `src/lane${index}/a.ts:${s}: match` } }],
                },
                sub,
              ),
            ],
          );
        }
        if (!running)
          steps.push([
            "in",
            "subagent_state_update",
            own(
              { sessionUpdate: "subagent_state_update" },
              { subagents: [{ id, parent: null, name, state: "completed", background: true }] },
            ),
          ]);
      }
      if (turn % 10 === 0) {
        const bg = `bash${turn}`;
        const command = `npm run watch -- ${turn}`;
        steps.push(
          [
            "in",
            "tool_call",
            own({
              sessionUpdate: "tool_call",
              toolCallId: bg,
              title: command,
              kind: "execute",
              status: "in_progress",
              rawInput: { command, run_in_background: true },
              _meta: { claude: { tool: "Bash" } },
            }),
          ],
          [
            "in",
            "tool_call_update",
            own({
              sessionUpdate: "tool_call_update",
              toolCallId: bg,
              status: "completed",
              content: [
                { type: "content", content: { type: "text", text: `Command running in background with ID: ${bg}` } },
              ],
            }),
          ],
          [
            "in",
            "background_task_update",
            own({
              sessionUpdate: "background_task_update",
              taskId: `task-${bg}`,
              toolCallId: bg,
              command,
              state: turn >= TURNS - 20 ? "running" : "completed",
            }),
          ],
        );
      }
      const last = turn === TURNS - 1;
      for (let n = 0; n < 3; n++)
        steps.push([
          "in",
          "agent_message_chunk",
          own({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `${paragraph(turn, n)}\n\n` } }),
        ]);
      steps.push([
        "in",
        "agent_message_chunk",
        own({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Batch ${turn} handed out.` } }),
      ]);
      if (!(last && working)) steps.push(["mux", "turn_result", { status: "completed" }]);
    }
    const events = steps.map(([dir, kind, msg], index) => ({
      sessionId: chatId,
      seq: index + 1,
      at: START + index * 500,
      dir,
      kind,
      msg,
    }));
    const session = {
      sessionId: chatId,
      cwd: "/home/dev/coordinator",
      title: working ? "Coordinator (working)" : "Coordinator",
      harness: "claude",
      family: "claude",
      status: working ? "working" : "idle",
      turnCount: TURNS,
      updatedAt: START + events.length * 500,
    };
    return { session, events, helpers };
  }

  const chats = new Map([IDLE, WORKING].map((id) => [id, chat(id, id === WORKING)] as const));
  const READY = `Batch ${TURNS - 1} handed out.`;

  function answer(method: string, params?: Record<string, any>): unknown {
    const fixture = chats.get(params?.sessionId) ?? chats.get(IDLE)!;
    const lastSeq = fixture.events.at(-1)?.seq ?? 0;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [...chats.values()].map((each) => each.session) };
      case "_acpmux/attach":
        return { session: fixture.session, lastSeq, events: fixture.events };
      case "_acpmux/events": {
        const after = params?.afterSeq ?? 0;
        const before = params?.beforeSeq ?? Number.POSITIVE_INFINITY;
        const events = fixture.events.filter((event) => event.seq > after && event.seq < before);
        return { events, hasMore: false, more: false, lastSeq };
      }
      default:
        return null;
    }
  }

  const sockets = new Set<{ send(data: string): void }>();
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
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(IDLE));
        await warm.getByText(READY).first().waitFor({ timeout: 40_000 });
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

  const LOOP = /Maximum update depth|Too many re-renders|#185|#301|render failed/;
  /// A fresh page with every error it logs, in full.
  async function fresh(): Promise<{ page: Page; errors: string[] }> {
    const page = await browser!.newPage({ viewport: { width: 1400, height: 900 } });
    const errors: string[] = [];
    page.on("console", (message) => {
      if (message.type() !== "error") return;
      const where = message.location();
      errors.push(`${message.text()}\n    (console at ${where.url}:${where.lineNumber}:${where.columnNumber})`);
    });
    page.on("pageerror", (error) => errors.push(`PAGEERROR ${error.message}\n${error.stack ?? ""}`));
    return { page, errors };
  }
  const reveal = (page: Page) =>
    page.evaluate(() => {
      const bridge = (window as unknown as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } })
        .cmuxAcpmuxBridge;
      bridge?.revealTurn?.("subagent:cmux:background-tasks");
      return bridge?.revealTurn !== undefined;
    });
  async function check(page: Page, errors: string[], what: string) {
    const loops = errors.filter((error) => LOOP.test(error));
    const failed = await page.locator(".acpmux-pane-failed").count();
    if (loops.length || failed) {
      console.log(`\n===== ${what}: ${loops.length} loop errors, pane failed: ${failed} =====`);
      for (const error of errors) console.log(`----- error -----\n${error}`);
      const failure = await page.evaluate(
        () => (window as unknown as { __cmuxPaneFailure?: unknown }).__cmuxPaneFailure,
      );
      console.log(`----- __cmuxPaneFailure -----\n${JSON.stringify(failure, null, 2)}`);
    } else console.log(`${what}: clean (${errors.length} other errors)`);
    expect(loops, what).toEqual([]);
    expect(failed, what).toBe(0);
  }

  test("a) the coordinator chat loads with no update loop", async () => {
    const { page, errors } = await fresh();
    try {
      await page.goto(url(IDLE));
      await page.getByText(READY).first().waitFor({ timeout: 40_000 });
      // fixed-wait: asserts an absence (no update loop) over the page's first seconds.
      await page.waitForTimeout(8_000);
      await check(page, errors, "a) load");
    } finally {
      await page.close();
    }
  });

  test("b) its Background tasks tab draws with no update loop", async () => {
    const { page, errors } = await fresh();
    try {
      await page.goto(url(IDLE));
      await page.getByText(READY).first().waitFor({ timeout: 40_000 });
      expect(await reveal(page)).toBe(true);
      await page.locator(".acpmux-bg").first().waitFor({ timeout: 15_000 });
      // fixed-wait: asserts an absence across several task-clock ticks.
      await page.waitForTimeout(6_000);
      await check(page, errors, "b) background tab");
    } finally {
      await page.close();
    }
  });

  test("c) drilling into a running and a finished subagent, scrolling, no update loop", async () => {
    const { page, errors } = await fresh();
    try {
      await page.goto(url(IDLE));
      await page.getByText(READY).first().waitFor({ timeout: 40_000 });
      await reveal(page);
      await page.locator(".acpmux-bg").first().waitFor({ timeout: 15_000 });
      const scrollTranscript = async () => {
        const transcript = page.locator(".acpmux-bg__transcript");
        if (!(await transcript.count())) return;
        for (const to of [0, 1e6, 0, 1e6]) {
          await transcript.evaluate((node, top) => (node.scrollTop = top), to);
          // fixed-wait: lets the sentinels' observers fire between scrolls.
          await page.waitForTimeout(300);
        }
      };
      const running = page.locator('.acpmux-bg__group[data-state="running"] .acpmux-bg__name:not([disabled])').first();
      if (await running.count()) {
        await running.click();
        await page.locator(".acpmux-bg__transcript").waitFor({ timeout: 10_000 });
        await scrollTranscript();
        // fixed-wait: asserts an absence (no update loop) while a running helper's drill-in shows.
        await page.waitForTimeout(2_000);
        await check(page, errors, "c) running drill-in");
        await page.locator(".acpmux-bg__head button").first().click();
      } else console.log("c) no running group to drill into");
      const finishedHead = page.locator('.acpmux-bg__section[data-section="finished"] > button');
      if ((await finishedHead.count()) && (await finishedHead.getAttribute("aria-expanded")) === "false")
        await finishedHead.click();
      const finished = page.locator('.acpmux-bg__group:not([data-state="running"]) .acpmux-bg__name:not([disabled])');
      console.log(`c) finished drillable: ${await finished.count()}`);
      if (await finished.count()) {
        await finished.nth(3).click();
        await page.locator(".acpmux-bg__transcript").waitFor({ timeout: 10_000 });
        await scrollTranscript();
      }
      // fixed-wait: asserts an absence after the drill-ins.
      await page.waitForTimeout(4_000);
      await check(page, errors, "c) finished drill-in");
    } finally {
      await page.close();
    }
  });

  for (const working of [false, true])
    test(`d) the tab reloaded with its reveal at once${working ? ", the chat working and a helper streaming" : ""}`, async () => {
      const { page, errors } = await fresh();
      const chatId = working ? WORKING : IDLE;
      const fixture = chats.get(chatId)!;
      let timer: ReturnType<typeof setInterval> | undefined;
      try {
        // The reveal lands as soon as the page's bridge exists, before the chat draws (a tab reloaded).
        await page.addInitScript(() => {
          const poll = () => {
            const bridge = (window as unknown as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } })
              .cmuxAcpmuxBridge;
            if (bridge?.revealTurn) bridge.revealTurn("subagent:cmux:background-tasks");
            else setTimeout(poll, 5);
          };
          poll();
        });
        await page.goto(url(chatId));
        await page.locator(".acpmux-bg").first().waitFor({ timeout: 40_000 });
        if (working) {
          const helper = fixture.helpers.at(-1)!;
          let seq = fixture.events.at(-1)!.seq;
          let step = 0;
          timer = setInterval(() => {
            const tool = `${helper.call}-live${step++}`;
            const sub = { sessionId: helper.id, tag: helper.id };
            for (const [kind, body] of [
              [
                "tool_call",
                {
                  sessionUpdate: "tool_call",
                  toolCallId: tool,
                  title: `ls /tmp/${step}`,
                  kind: "execute",
                  status: "in_progress",
                  rawInput: { command: `ls /tmp/${step}` },
                },
              ],
              ["tool_call_update", { sessionUpdate: "tool_call_update", toolCallId: tool, status: "completed" }],
            ] as const) {
              seq += 1;
              const event = { sessionId: chatId, seq, at: Date.now(), dir: "in", kind, msg: update(body, sub) };
              fixture.events.push(event);
              const frame = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event });
              for (const socket of sockets) socket.send(frame);
            }
          }, 200);
          // Drill into the streaming helper too.
          const running = page
            .locator('.acpmux-bg__group[data-state="running"] .acpmux-bg__name:not([disabled])')
            .first();
          if (await running.count()) await running.click();
        }
        // fixed-wait: asserts an absence while the page settles (and streams).
        await page.waitForTimeout(10_000);
        await check(page, errors, `d) reload${working ? " working" : ""}`);
      } finally {
        if (timer) clearInterval(timer);
        await page.close();
      }
    });
});
