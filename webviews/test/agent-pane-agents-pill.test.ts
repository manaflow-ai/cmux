// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// By default running subagents sit in one tray above the composer (subagents/SubagentTray.tsx): the
// transcript has no running card and there is no pill; a subagent that ends leaves one line where it
// ended. The tests below the first cover the older presentation, which Debug Settings
// agentPane.debug.subagentTray off keeps (the host pushes `subagentTray: false` with the theme).
// With it, while a chat's subagents run, a pill sits right above the composer, after Codex's phone app ("3
// agents"): it counts the agents still running and opens a list split into Active and Completed,
// a colored dot per agent. The same color marks the agent's name in the transcript, and an agent
// keeps it for the life of the chat as others start and end. A click on an agent opens it. The
// pill shows only while an agent runs, and streamed text never redraws it. The page is the pane's
// dev entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon that can push live
// events.
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
  const NESTED = "0190a000-0000-7000-8000-0000000000a4";
  const START = Date.now() - 90_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const spawned = (id: string, name: string, parent: string | null = null): Step => [
    "in",
    "subagent_spawned",
    update({ sessionUpdate: "subagent_spawned" }, { subagents: [{ id, parent, name, state: "running" }] }),
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
  // Reviewer spawned an agent of its own after Tester started.
  const nested: Step[] = [
    ...start,
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    spawned("a5", "Scout", "a1"),
    reading,
  ];
  const record = (session: string, step: Step, seq: number) => {
    const [dir, kind, msg] = step;
    return { sessionId: session, seq, at: START + seq * 1000, dir, kind, msg };
  };
  const chats: Record<string, ReturnType<typeof record>[]> = {
    [BUSY]: busy.map((step, index) => record(BUSY, step, index + 1)),
    [QUIET]: quiet.map((step, index) => record(QUIET, step, index + 1)),
    [STUCK]: stuck.map((step, index) => record(STUCK, step, index + 1)),
    [NESTED]: nested.map((step, index) => record(NESTED, step, index + 1)),
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
        return {
          sessions: [session(BUSY), session(QUIET), { ...session(STUCK), status: "idle" }, session(NESTED)],
        };
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
  /// The older presentation: transcript group cards and the agents pill (Debug Settings
  /// agentPane.debug.subagentTray off, which the host sends with the theme).
  const trayOff = (page: Page) =>
    page.evaluate(() =>
      (window as any).cmuxAcpmuxBridge.applyTheme({ isDark: true, subagentTray: false }),
    ) as Promise<void>;
  const open = async (session: string, shown = "Read app.ts", tray = false) => {
    sockets.clear();
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(session));
    // The read in flight draws no row of its own (Debug toggle agentPane.debug.codexToolRuns, on by
    // default): the turn's live line names it by its file (Thinking.tsx).
    await page.getByText(shown).first().waitFor({ timeout: 25_000 });
    if (!tray) await trayOff(page);
    return page;
  };
  const tray = (page: Page) => page.locator(".acpmux-running-tray");
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
  /// Counts the pill's renders from React's devtools hook, installed before the page's scripts: each
  /// commit, the pill's fiber rendered when it is a new fiber object with React's PerformedWork flag
  /// (a memo bailout clones the fiber without the flag; a skipped subtree keeps the last object).
  const countPillRenders = () => {
    const performedWork = 1;
    let last: object | undefined;
    const counter = { renders: 0 };
    (window as any).__pillRenders = counter;
    const find = (fiber: any): any => {
      for (let node = fiber; node; node = node.sibling) {
        if (node.type?.name === "AgentsPill") return node;
        const found = node.child && find(node.child);
        if (found) return found;
      }
      return undefined;
    };
    (window as any).__REACT_DEVTOOLS_GLOBAL_HOOK__ = {
      supportsFiber: true,
      renderers: new Map(),
      inject: () => 1,
      onCommitFiberUnmount: () => {},
      onPostCommitFiberRoot: () => {},
      onCommitFiberRoot: (_id: number, root: any) => {
        const pill = find(root.current);
        if (pill && pill !== last && (pill.alternate === null || (pill.flags & performedWork) !== 0)) counter.renders++;
        last = pill;
      },
    };
  };
  const pillRenders = (page: Page) => page.evaluate(() => (window as any).__pillRenders.renders as number);
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

  test("by default the running agents sit in the tray above the composer, not in the transcript", async () => {
    const page = await open(BUSY, "Read app.ts", true);
    await tray(page).waitFor({ timeout: 5_000 });
    // Reviewer and Tester run; the Linter ended and stays as a finished card under them
    // (49acdd1d589d keeps finished cards mounted in the tray).
    const running = tray(page).locator("li:not([data-finished])");
    expect(await running.locator(".acpmux-summary-agent__name").allTextContents()).toEqual(["Reviewer", "Tester"]);
    expect(await running.locator(".acpmux-agent-line__time").count()).toBe(2);
    expect(await tray(page).locator("li[data-finished] .acpmux-summary-agent__name").allTextContents()).toEqual([
      "Linter",
    ]);
    expect(await page.locator(".cv-subagents").count()).toBe(0);
    expect(await page.locator(".cv-subagent").count()).toBe(0);
    expect(await pill(page).count()).toBe(0);
    const [trayBox, composerBox] = await Promise.all([
      tray(page).boundingBox(),
      page.locator(".acpmux-composer").first().boundingBox(),
    ]);
    expect(trayBox!.y + trayBox!.height).toBeLessThanOrEqual(composerBox!.y);
    // Both end: nothing runs in the tray, which keeps them as finished cards (49acdd1d589d), and
    // each leaves its line.
    push(finished("a1", "Reviewer"));
    push(finished("a2", "Tester"));
    await running.first().waitFor({ state: "detached", timeout: 5_000 });
    expect(await running.count()).toBe(0);
    expect(
      (await tray(page).locator("li[data-finished] .acpmux-summary-agent__name").allTextContents()).sort(),
    ).toEqual(["Linter", "Reviewer", "Tester"]);
    // Each leaves one line where it ended, at the transcript's end.
    await page.locator(".cv-subagent-done", { hasText: "Reviewer" }).waitFor({ timeout: 5_000 });
    await page.locator(".cv-subagent-done", { hasText: "Tester" }).waitFor({ timeout: 5_000 });
    await page.close();
    // An agent spawned by another sits right under it in the tray.
    const nested = await open(NESTED, "Read app.ts", true);
    await tray(nested).waitFor({ timeout: 5_000 });
    expect(await tray(nested).locator(".acpmux-summary-agent__name").allTextContents()).toEqual([
      "Reviewer",
      "Scout",
      "Tester",
    ]);
    await nested.close();
    // The turn is over: an agent left "running" by a cancel or a reconnect pins no running row; the
    // tray keeps it only as a stopped card (49acdd1d589d keeps ended cards).
    const stale = await open(STUCK, "Review the branch with a few agents", true);
    expect(await tray(stale).locator("li:not([data-finished])").count()).toBe(0);
    expect(await tray(stale).locator('li[data-finished] .acpmux-agent-line[data-status="stopped"]').count()).toBe(1);
    await stale.close();
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
        // The running line is the turn's last row (agentPane.debug.liveLineBelow).
        page.locator(".acpmux-row").last().boundingBox(),
        pill(page).boundingBox(),
      ]);
      return box!.y - (latest!.y + latest!.height);
    };
    await page
      .waitForFunction(
        () => {
          const rows = document.querySelectorAll(".acpmux-row");
          const latest = rows[rows.length - 1]?.getBoundingClientRect();
          const box = document.querySelector(".acpmux-agents-pill")?.getBoundingClientRect();
          return !!latest && !!box && box.y - latest.bottom >= 0;
        },
        null,
        { timeout: 5_000 },
      )
      .catch(() => {});
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

  test("an agent spawned by another sits right under it, indented", async () => {
    const page = await open(NESTED);
    await pill(page).click();
    await list(page).waitFor({ timeout: 5_000 });
    const rows = await list(page)
      .locator(".acpmux-agents-list__row")
      .evaluateAll((nodes) =>
        nodes.map((node) => ({
          name: node.querySelector(".acpmux-agents-list__name")!.textContent,
          dot: node.querySelector(".acpmux-agents-list__dot")!.getBoundingClientRect().left,
        })),
      );
    expect(rows.map((row) => row.name)).toEqual(["Reviewer", "Scout", "Tester"]);
    const [reviewer, scout, tester] = rows;
    expect(scout!.dot).toBeGreaterThan(reviewer!.dot + 8);
    expect(tester!.dot).toBe(reviewer!.dot);
    await page.close();
  });

  test("an agent's color marks its name in the transcript, and holds as others start and on reload", async () => {
    const page = await open(BUSY);
    await pill(page).click();
    await list(page).waitFor({ timeout: 5_000 });
    const before = await dots(page);
    await page.keyboard.press("Escape");
    // The transcript's group, open while its agents run: each name in its agent's color.
    await page.locator(".cv-subagent__name").nth(2).waitFor({ timeout: 5_000 });
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
    await pill(page)
      .first()
      .waitFor({ state: "detached", timeout: 5_000 })
      .catch(() => {});
    expect(await pill(page).count()).toBe(0);
    await page.close();
  });

  test("streamed text never redraws the pill", async () => {
    sockets.clear();
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(countPillRenders);
    await page.goto(url(BUSY));
    await page.getByText("Read app.ts").first().waitFor({ timeout: 25_000 });
    await trayOff(page);
    await pill(page).filter({ hasText: "2 agents" }).waitFor({ timeout: 25_000 });
    const before = await pillRenders(page);
    expect(before).toBeGreaterThan(0);
    for (let chunk = 1; chunk <= 12; chunk++) {
      push([
        "in",
        "agent_message_chunk",
        update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: ` Streamed word ${chunk}.` } }),
      ]);
      await page.getByText(`Streamed word ${chunk}.`, { exact: false }).first().waitFor({ timeout: 5_000 });
    }
    expect(await pillRenders(page)).toBe(before);
    // The counter sees a change the pill shows: a third agent starts.
    push(spawned("a5", "Packager"));
    await pill(page).filter({ hasText: "3 agents" }).waitFor({ timeout: 5_000 });
    expect(await pillRenders(page)).toBeGreaterThan(before);
    await page.close();
  });
});
