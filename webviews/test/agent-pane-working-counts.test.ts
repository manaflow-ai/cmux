// l10n-allow-file: test fixture prompts, replies, commands and subagent names, not shipped UI.
// The running turn's line counts the work still going in the background, after Claude's phone
// app ("Working… · 5 running tasks"): "Read app.ts 3s · 2 subagents · 1 command", on the turn's one
// live line at its bottom. It counts only
// subagents still running and background shells that have not ended, each count opens what it
// counts, and a count never moves the line or the rows under it. That is the presentation with the
// running tray off (Debug Settings agentPane.debug.subagentTray); with the tray on, the default, the
// tray above the composer is the count and the line counts nothing. The page is the pane's dev
// entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { openRunningTray } from "./support/openRunningTray";

await requireBrowserLane("agent-pane-working-counts.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-working-counts: skipping (run `bunx playwright install chromium`)");
    describe.skip("working counts", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const BUSY = "0190a000-0000-7000-8000-0000000000f1";
  const QUIET = "0190a000-0000-7000-8000-0000000000f2";
  // Recent, so the line reads seconds or minutes.
  const START = Date.now() - 90_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// A Bash call Claude ran in the background: its result is only the launch.
  const background = (id: string, command: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
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
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: `Command running in background with ID: ${id}` } }],
      }),
    ],
  ];
  const ended = (id: string, command: string, state: string): Step => [
    "in",
    "background_task_update",
    update({ sessionUpdate: "background_task_update", taskId: `task-${id}`, toolCallId: id, command, state }),
  ];
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
  // A reply long enough that the first turn is far above the running line.
  const longReply = Array.from(
    { length: 40 },
    (_, index) => `Paragraph ${index + 1}: the dev server and the watcher keep running while we work.`,
  ).join("\n\n");
  const reading = (id: string): Step => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: "Read src/app.ts",
      kind: "read",
      status: "in_progress",
      rawInput: { file_path: "src/app.ts" },
    }),
  ];
  const busy: Step[] = [
    ["mux", "user_message", { text: "Start the dev server and the test watcher" }],
    ["mux", "turn_started", {}],
    ...background("bg1", "npm run dev"),
    ...background("bg2", "cargo watch -x test"),
    ["in", "agent_message_chunk", say(longReply)],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Review the branch with a few agents" }],
    ["mux", "turn_started", {}],
    ended("bg2", "cargo watch -x test", "stopped"),
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    spawned("a3", "Linter"),
    finished("a3", "Linter"),
    reading("read1"),
  ];
  // The same turn with nothing in the background.
  const quiet: Step[] = [
    ["mux", "user_message", { text: "Start the dev server and the test watcher" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say(longReply)],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Review the branch with a few agents" }],
    ["mux", "turn_started", {}],
    reading("read1"),
  ];
  const events = (steps: Step[], session: string) =>
    steps.map(([dir, kind, msg], index) => ({
      sessionId: session,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
  const chats: Record<string, ReturnType<typeof events>> = {
    [BUSY]: events(busy, BUSY),
    [QUIET]: events(quiet, QUIET),
  };
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Review",
    harness: "claude",
    family: "claude",
    status: "working",
    turnCount: 2,
    updatedAt: START,
  });

  function answer(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(BUSY), session(QUIET)] };
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
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  /// The tray off, as the host sends it with the theme, unless `tray`.
  const open = async (session: string, width = 900, tray = false) => {
    const page = await browser!.newPage({ viewport: { width, height: 760 } });
    await page.goto(url(session));
    await line(page).waitFor({ timeout: 25_000 });
    if (!tray)
      await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTheme({ isDark: true, subagentTray: false }));
    return page;
  };
  // The running turn's one live line at its bottom (Thinking.tsx, Debug toggles codexToolRuns and
  // liveLineBelow, on by default): it names the read in flight, then the counts.
  const line = (page: Page) => page.locator(".cv-worked.is-below");
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
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

  test("the line counts the subagents and background shells still running", async () => {
    const page = await open(BUSY);
    // The Linter finished and the watcher stopped: neither counts.
    expect((await line(page).innerText()).replace(/\s+/g, " ").trim()).toMatch(
      /^Read [^·]+ · 2 subagents · 1 command$/,
    );
    await page.close();
    const plain = await open(QUIET);
    expect((await line(plain).innerText()).replace(/\s+/g, " ").trim()).toMatch(/^Read [^·]+$/);
    await plain.close();
  });

  test("with the tray on, the line counts nothing: the tray lists the same work", async () => {
    const page = await open(BUSY, 900, true);
    const tray = page.locator(".acpmux-running-tray");
    await tray.waitFor({ timeout: 5_000 });
    // It starts folded to its header (cmux#28875); the person opens it.
    await openRunningTray(page);
    // What runs is listed first; the Linter that ended stays as a finished card under it
    // (49acdd1d589d keeps finished cards mounted in the tray).
    const lines = await tray
      .locator("li:not([data-finished]) .acpmux-agent-line .acpmux-summary-agent__name")
      .allInnerTexts();
    expect(lines).toEqual(["Reviewer", "Tester", "npm run dev"]);
    expect(await tray.locator("li[data-finished] .acpmux-summary-agent__name").allInnerTexts()).toEqual(["Linter"]);
    expect((await line(page).innerText()).replace(/\s+/g, " ").trim()).toMatch(/^Read [^·]+$/);
    await page.close();
  });

  test("a count moves nothing: the line keeps its box and its label stays put", async () => {
    for (const width of [900, 420]) {
      const measure = async (session: string) => {
        const page = await open(session, width);
        const box = await line(page).evaluate((node) => {
          const label = node.querySelector(".cv-thinking")!.getBoundingClientRect();
          const row = node.getBoundingClientRect();
          // The line's box is one meta row plus the turn gap it reserves under it (625f2e3d1b32). On the
          // grid (#27580, design/grid.md 5.5) --cv-meta-row is a calc() of --grid-transcript-action-control
          // and --cv-turn-gap is 0 (the stack owns the gap), so the tokens are resolved by layout, not
          // parseFloat (which read NaN from the calc()).
          const probe = document.createElement("div");
          probe.style.cssText = "position:absolute;visibility:hidden;height:calc(var(--cv-meta-row) + var(--cv-turn-gap))";
          node.appendChild(probe);
          const oneLine = probe.getBoundingClientRect().height;
          probe.remove();
          return {
            height: row.height,
            labelLeft: label.left - row.left,
            labelHeight: label.height,
            oneLine,
          };
        });
        await page.close();
        return box;
      };
      const busyBox = await measure(BUSY);
      expect(busyBox).toEqual(await measure(QUIET));
      // One 20px line, even in a narrow pane: the line's box holds one line and the turn gap it
      // reserves below it (fec3ac0e5125, 625f2e3d1b32); a second line would grow it by 20px.
      expect(busyBox.height).toBe(busyBox.oneLine);
      expect(busyBox.labelHeight).toBe(20);
    }
  });

  test("the command count opens the shell's row", async () => {
    const page = await open(BUSY);
    const command = line(page).getByRole("button", { name: "1 command" });
    await command.click();
    // The first turn's "Worked for" opens, and its Bash row scrolls into view.
    const row = page.locator(".cv-tool", { hasText: "npm run dev" }).first();
    await row.waitFor({ timeout: 5_000 });
    const inView = () =>
      row.evaluate((node) => {
        const box = node.getBoundingClientRect();
        return box.top >= 0 && box.bottom <= window.innerHeight;
      });
    // The scroll can glide: wait for the row to come into view, then check it is.
    await page
      .waitForFunction(
        (node) => {
          const box = node!.getBoundingClientRect();
          return box.top >= 0 && box.bottom <= window.innerHeight;
        },
        await row.elementHandle(),
        { timeout: 5_000 },
      )
      .catch(() => undefined);
    expect(await inView()).toBe(true);
    await page.close();
  });

  test("the agent count opens the list of the chat's agents", async () => {
    const page = await open(BUSY);
    await line(page).getByRole("button", { name: "2 subagents" }).click();
    const list = page.getByRole("region", { name: "Subagents" });
    await list.waitFor({ timeout: 5_000 });
    expect(await list.getByText("Reviewer").isVisible()).toBe(true);
    await page.close();
  });
});
