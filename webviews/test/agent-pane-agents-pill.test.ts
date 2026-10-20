// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// While a chat's subagents run, a pill sits right above the composer, after Codex's phone app ("3
// agents"): it counts the agents still running and opens a list split into Active and Completed,
// a colored dot per agent. The same color marks the agent's name in the transcript, and an agent
// keeps it for the life of the chat as others start and end. A click on an agent opens it. The
// pill shows only while an agent runs. The page is the pane's dev entry with its browser host,
// talking JSON-RPC to a stand-in acpmux daemon that can push live events.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-agents-pill.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-agents-pill: skipping (run `bunx playwright install chromium`)");
    describe.skip("agents pill", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const BUSY = "0190a000-0000-7000-8000-0000000000a1";
  const QUIET = "0190a000-0000-7000-8000-0000000000a2";
  const STUCK = "0190a000-0000-7000-8000-0000000000a3";
  const START = Date.now() - 90_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const spawned = (id: string, name: string): Step => [
    "in",
    "subagent_spawned",
    update({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id, parent: null, name, state: "running" }] }),
  ];
  const finished = (id: string, name: string): Step => [
    "in",
    "subagent_state_update",
    update({ sessionUpdate: "subagent_state_update" }, { subagents: [{ id, parent: null, name, state: "completed" }] }),
  ];
  const reading: Step = [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: "read1",
      title: "Read src/app.ts",
      kind: "read",
      status: "in_progress",
      rawInput: { file_path: "src/app.ts" },
    }),
  ];
  const start: Step[] = [
    ["mux", "user_message", { text: "Review the branch with a few agents" }],
    ["mux", "turn_started", {}],
  ];
  // A reply long enough that the chat opens scrolled to its end.
  const reply: Step = [
    "in",
    "agent_message_chunk",
    update({
      sessionUpdate: "agent_message_chunk",
      content: {
        type: "text",
        text: Array.from({ length: 40 }, (_, index) => `Paragraph ${index + 1} while the agents work.`).join("\n\n"),
      },
    }),
  ];
  const busy: Step[] = [
    ...start,
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    spawned("a3", "Linter"),
    finished("a3", "Linter"),
    reply,
    reading,
  ];
  const quiet: Step[] = [
    ...start,
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    finished("a1", "Reviewer"),
    finished("a2", "Tester"),
    reading,
  ];
  // The turn ended (cancelled, or the daemon reconnected) with an agent never reported done.
  const stuck: Step[] = [...start, spawned("a1", "Reviewer"), reading, ["mux", "turn_result", { status: "cancelled" }]];
  const record = (session: string, step: Step, seq: number) => {
    const [dir, kind, msg] = step;
    return { sessionId: session, seq, at: START + seq * 1000, dir, kind, msg };
  };
  const chats: Record<string, ReturnType<typeof record>[]> = {
    [BUSY]: busy.map((step, index) => record(BUSY, step, index + 1)),
    [QUIET]: quiet.map((step, index) => record(QUIET, step, index + 1)),
    [STUCK]: stuck.map((step, index) => record(STUCK, step, index + 1)),
  };
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Review",
    harness: "claude",
    family: "claude",
    status: "working",
    turnCount: 1,
    updatedAt: START,
  });

  function answer(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(BUSY), session(QUIET), { ...session(STUCK), status: "idle" }] };
      case "_acpmux/attach": {
        const id = typeof params.sessionId === "string" && chats[params.sessionId] ? params.sessionId : BUSY;
        return { session: session(id), lastSeq: chats[id]!.length, events: chats[id] };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const sockets = new Set<{ send(data: string): void }>();
  /// Sends a live event of BUSY to every page attached now, after its loaded history.
  let liveSeq = busy.length;
  const push = (step: Step) => {
    const event = record(BUSY, step, ++liveSeq);
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  const open = async (session: string, shown = "Read src/app.ts") => {
    sockets.clear();
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(session));
    await page.getByText(shown).waitFor({ timeout: 25_000 });
    return page;
  };
  const pill = (page: Page) => page.locator(".acpmux-agents-pill");
  const list = (page: Page) => page.getByRole("dialog", { name: "Agents" });
  /// Each agent's dot color in the open list, by name.
  const dots = (page: Page) =>
    list(page)
      .locator(".acpmux-agents-list__row")
      .evaluateAll((rows) =>
        Object.fromEntries(
          rows.map((row) => [
            row.querySelector(".acpmux-agents-list__name")!.textContent,
            getComputedStyle(row.querySelector(".acpmux-agents-list__dot")!).backgroundColor,
          ]),
        ),
      );
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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      try {
        await (await open(BUSY)).close();
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

  test("a pill above the composer counts the agents still running", async () => {
    const page = await open(BUSY);
    await pill(page).waitFor({ timeout: 5_000 });
    expect((await pill(page).innerText()).trim()).toBe("2 agents");
    const [pillBox, composerBox] = await Promise.all([
      pill(page).boundingBox(),
      page.locator(".acpmux-composer").first().boundingBox(),
    ]);
    expect(pillBox!.y + pillBox!.height).toBeLessThanOrEqual(composerBox!.y);
    // At the chat's end the latest row stays clear of the pill, once following the bottom has
    // taken in the height the pill took.
    const clearance = async () => {
      const [latest, box] = await Promise.all([
        page.getByText("Read src/app.ts").boundingBox(),
        pill(page).boundingBox(),
      ]);
      return box!.y - (latest!.y + latest!.height);
    };
    for (let tries = 0; tries < 20 && (await clearance()) < 0; tries++) await page.waitForTimeout(50);
    expect(await clearance()).toBeGreaterThanOrEqual(0);
    await page.close();
    // No agent running: no pill.
    const done = await open(QUIET);
    expect(await pill(done).count()).toBe(0);
    await done.close();
    // The turn is over: an agent left "running" by a cancel or a reconnect pins no pill.
    // Its work folds under Worked for; the prompt shows.
    const stale = await open(STUCK, "Review the branch with a few agents");
    expect(await pill(stale).count()).toBe(0);
    await stale.close();
  });

  test("the list splits active from completed, with a colored dot per agent", async () => {
    const page = await open(BUSY);
    await pill(page).click();
    await list(page).waitFor({ timeout: 5_000 });
    const sections = await list(page)
      .locator(".acpmux-agents-list__section")
      .evaluateAll((nodes) =>
        nodes.map((node) => [
          node.querySelector(".acpmux-agents-list__heading")!.textContent,
          [...node.querySelectorAll(".acpmux-agents-list__name")].map((name) => name.textContent),
        ]),
      );
    expect(sections).toEqual([
      ["Active", ["Reviewer", "Tester"]],
      ["Completed", ["Linter"]],
    ]);
    const colors = await dots(page);
    expect(new Set(Object.values(colors)).size).toBe(3);
    await page.close();
  });

  test("an agent's color marks its name in the transcript, and holds as others start and on reload", async () => {
    const page = await open(BUSY);
    await pill(page).click();
    await list(page).waitFor({ timeout: 5_000 });
    const before = await dots(page);
    await page.keyboard.press("Escape");
    // The transcript's group, opened: each name in its agent's color.
    await page.getByRole("button", { name: /3 subagents/ }).click();
    const names = await page
      .locator(".cv-subagent__name")
      .evaluateAll((nodes) =>
        Object.fromEntries(nodes.map((node) => [node.firstChild!.textContent, getComputedStyle(node).color])),
      );
    expect(names).toEqual(before);
    // A fourth agent starts: the others keep their colors.
    push(spawned("a4", "Formatter"));
    await pill(page).filter({ hasText: "3 agents" }).waitFor({ timeout: 5_000 });
    await pill(page).click();
    await list(page).waitFor({ timeout: 5_000 });
    const after = await dots(page);
    expect(Object.fromEntries(Object.keys(before).map((name) => [name, after[name]]))).toEqual(before);
    await page.close();
    // A reload colors each agent as before: the color comes from the agent's id alone.
    const again = await open(BUSY);
    await pill(again).click();
    await list(again).waitFor({ timeout: 5_000 });
    expect(await dots(again)).toEqual(before);
    await again.close();
  });

  test("a click on an agent opens it, and the pill goes once none runs", async () => {
    const page = await open(BUSY);
    await pill(page).click();
    await list(page)
      .getByRole("button", { name: /Reviewer/ })
      .click();
    // The dev host opens no pane of its own, so the agent's view shows in this pane.
    await page.locator(".cv-subagent-of").waitFor({ timeout: 5_000 });
    expect(await list(page).count()).toBe(0);
    push(finished("a1", "Reviewer"));
    push(finished("a2", "Tester"));
    for (let tries = 0; tries < 50 && (await pill(page).count()) > 0; tries++) await page.waitForTimeout(100);
    expect(await pill(page).count()).toBe(0);
    await page.close();
  });
});
