// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// With Debug Settings agentPane.debug.subagentTray off (the tray is the default), a transcript group of subagents (subagents/SubagentGroup.tsx) starts open while its agents run
// in the working turn, so their lines show without a click, after Codex and Claude Code. A finished
// chat's groups start closed. A group the person closes stays closed as its agents work, and the
// open and closed groups are the chat's own: another chat's group at the same place starts as its
// own rule says. The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux daemon that can push live events.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-subagent-groups-open.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-subagent-groups-open: skipping (run `bunx playwright install chromium`)");
    describe.skip("subagent groups open", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LIVE = "0190a000-0000-7000-8000-0000000000b1";
  const DONE = "0190a000-0000-7000-8000-0000000000b2";
  const OTHER = "0190a000-0000-7000-8000-0000000000b3";
  const STALE = "0190a000-0000-7000-8000-0000000000b4";
  const START = Date.now() - 90_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const agentUpdate = (kind: string, id: string, name: string, state: string): Step => [
    "in",
    kind,
    update({ sessionUpdate: kind }, { subagents: [{ id, parent: null, name, state }] }),
  ];
  const spawned = (id: string, name: string) => agentUpdate("subagent_spawned", id, name, "running");
  const finished = (id: string, name: string) => agentUpdate("subagent_state_update", id, name, "completed");
  const read = (id: string, file: string): Step => [
    "in",
    "tool_call",
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: `Read ${file}`,
      kind: "read",
      status: "completed",
      rawInput: { file_path: file },
    }),
  ];
  const start: Step[] = [
    ["mux", "user_message", { text: "Review the branch with a few agents" }],
    ["mux", "turn_started", {}],
  ];
  const reply = (text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
  ];
  // The read that ends the live turn is its live line ("Read app.ts"), so pages wait on the prompt.
  const live: Step[] = [...start, spawned("a1", "Reviewer"), spawned("a2", "Tester"), read("r1", "src/app.ts")];
  // Finished chats, their group at the same place as LIVE's.
  const done = (answer: string): Step[] => [
    ...start,
    spawned("a1", "Reviewer"),
    spawned("a2", "Tester"),
    finished("a1", "Reviewer"),
    finished("a2", "Tester"),
    reply(answer),
    ["mux", "turn_result", { status: "completed" }],
  ];
  // A cancel left an agent "running" in the first turn; the second turn works now.
  const stale: Step[] = [
    ...start,
    spawned("a1", "Reviewer"),
    reply("Starting the review."),
    ["mux", "turn_result", { status: "cancelled" }],
    ["mux", "user_message", { text: "Now fix the tests" }],
    ["mux", "turn_started", {}],
    read("r9", "src/tests.ts"),
  ];
  const record = (session: string, step: Step, seq: number) => {
    const [dir, kind, msg] = step;
    return { sessionId: session, seq, at: START + seq * 1000, dir, kind, msg };
  };
  const chats: Record<string, ReturnType<typeof record>[]> = {
    [LIVE]: live.map((step, index) => record(LIVE, step, index + 1)),
    [DONE]: done("Both reviews are in.").map((step, index) => record(DONE, step, index + 1)),
    [OTHER]: done("The other review is in.").map((step, index) => record(OTHER, step, index + 1)),
    [STALE]: stale.map((step, index) => record(STALE, step, index + 1)),
  };
  const working = new Set([LIVE, STALE]);
  const session = (sessionId: string, status = "idle") => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Review",
    harness: "claude",
    family: "claude",
    status,
    turnCount: 1,
    updatedAt: START,
  });

  function answer(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: Object.keys(chats).map((id) => session(id, working.has(id) ? "working" : "idle")) };
      case "_acpmux/attach": {
        const id = typeof params.sessionId === "string" && chats[params.sessionId] ? params.sessionId : LIVE;
        return {
          session: session(id, working.has(id) ? "working" : "idle"),
          lastSeq: chats[id]!.length,
          events: chats[id],
        };
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
  /// Sends a live event of LIVE to every page attached now, after its loaded history.
  let liveSeq = live.length;
  const push = (step: Step) => {
    const event = record(LIVE, step, ++liveSeq);
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  const open = async (session: string, shown: string) => {
    sockets.clear();
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url(session));
    await page.getByText(shown).first().waitFor({ timeout: 25_000 });
    // Group cards are the older presentation: by default running subagents sit in the tray above
    // the composer. The host turns the tray off with the theme (Debug Settings
    // agentPane.debug.subagentTray); the removed running-activity pill is not part of this mode.
    await page.evaluate(() => (window as any).cmuxAcpmuxBridge.applyTheme({ isDark: true, subagentTray: false }));
    return page;
  };
  const select = (page: Page, sessionId: string) =>
    page.evaluate((sessionId) => {
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.select"]?.({ sessionId });
    }, sessionId);
  const groups = (page: Page) => page.locator("button.cv-subagents");
  const lines = (page: Page) => page.locator(".cv-subagent");
  type Groups = { open: (string | null)[]; lines: number };
  /// The open groups and the lines they list, as the page draws them.
  const shown = (page: Page) =>
    page.evaluate(() => {
      const open = [...document.querySelectorAll("button.cv-subagents")].map((node) =>
        node.getAttribute("aria-expanded"),
      );
      return { open, lines: document.querySelectorAll(".cv-subagent").length };
    });
  /// Expects the page to show `want`: once it does (or after 4 s, so the expect says what it was), and
  /// still so once the next frame has painted.
  const expectGroups = async (page: Page, want: Groups) => {
    await page
      .waitForFunction(
        (want) => {
          const open = [...document.querySelectorAll("button.cv-subagents")].map((node) =>
            node.getAttribute("aria-expanded"),
          );
          return JSON.stringify({ open, lines: document.querySelectorAll(".cv-subagent").length }) === want;
        },
        JSON.stringify(want),
        { timeout: 4_000 },
      )
      .catch(() => {});
    await page.evaluate(() => window.cmuxPaintFrame());
    expect(await shown(page)).toEqual(want);
  };
  /// Waits until the first group's line (its count and states) is no longer `before`.
  const lineChanged = (page: Page, before: string) =>
    page.waitForFunction((before) => document.querySelector("button.cv-subagents")?.textContent !== before, before, {
      timeout: 5_000,
    });
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
        await (await open(LIVE, "Review the branch with a few agents")).close();
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

  test("a group of running agents starts open; a finished chat's starts closed", async () => {
    const page = await open(LIVE, "Review the branch with a few agents");
    await lines(page).first().waitFor({ timeout: 5_000 });
    await expectGroups(page, { open: ["true"], lines: 2 });
    await page.close();
    const finished = await open(DONE, "Both reviews are in.");
    await expectGroups(finished, { open: ["false"], lines: 0 });
    await finished.close();
  });

  test("a group the person closes stays closed as its agents work; a later group opens on its own", async () => {
    const page = await open(LIVE, "Review the branch with a few agents");
    await lines(page).first().waitFor({ timeout: 5_000 });
    await groups(page).first().click();
    await expectGroups(page, { open: ["false"], lines: 0 });
    const line = await groups(page).first().innerText();
    push(finished("a1", "Reviewer"));
    // The group heard it: its line now counts one done.
    await lineChanged(page, line);
    await expectGroups(page, { open: ["false"], lines: 0 });
    // The turn goes on: the agent writes, then starts another batch.
    push(reply("Both reviews started; now a lint pass."));
    push(spawned("a3", "Linter"));
    await page.getByText("Linter").waitFor({ timeout: 5_000 });
    await expectGroups(page, { open: ["false", "true"], lines: 1 });
    await page.close();
  });

  test("a chat's open groups are its own: another chat's group at the same place starts closed", async () => {
    const page = await open(DONE, "Both reviews are in.");
    await groups(page).first().click();
    await expectGroups(page, { open: ["true"], lines: 2 });
    await select(page, OTHER);
    await page.getByText("The other review is in.").waitFor({ timeout: 10_000 });
    await expectGroups(page, { open: ["false"], lines: 0 });
    // Back in the first chat, its group is open as it was left.
    await select(page, DONE);
    await page.getByText("Both reviews are in.").waitFor({ timeout: 10_000 });
    await expectGroups(page, { open: ["true"], lines: 2 });
    await page.close();
  });

  test("a running group the person closed stays closed after a switch away and back", async () => {
    const page = await open(LIVE, "Review the branch with a few agents");
    await lines(page).first().waitFor({ timeout: 5_000 });
    await groups(page).first().click();
    await expectGroups(page, { open: ["false"], lines: 0 });
    await select(page, DONE);
    await page.getByText("Both reviews are in.").waitFor({ timeout: 10_000 });
    await select(page, LIVE);
    await page.getByText("Read app.ts").first().waitFor({ timeout: 10_000 });
    await expectGroups(page, { open: ["false"], lines: 0 });
    await page.close();
  });

  test("an earlier turn's agent a cancel left running opens nothing when the next turn works", async () => {
    const page = await open(STALE, "Now fix the tests");
    await expectGroups(page, { open: ["false"], lines: 0 });
    await page.close();
  });
});
