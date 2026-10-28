// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// A chat's background shells (cx-ncc.84, Claude parity). Claude's Bash calls that run in the
// background end with acpmux's `background_task_update`. The call's own "Ran" row says how its
// shell stands (running in the background, then stopped or finished), in whichever turn it ended;
// a shell whose call is not in the transcript is noted where it ended, in a few words
// ("Background task finished: pytest -x"). The Inspector's Background tasks (Debug Settings
// `agent.inspector`; with it off, the header's summary) lists the chat's background tasks with how
// each stands, the ones only the transcript knows included (this daemon keeps no process registry).
// A click on a task's row in the Inspector or the summary opens the task's terminal
// (`chat.processTerminal`, background-task-terminal-DESIGN.md). A click on a note opens it in place
// (the whole command, how it ended), never a terminal; only its Open in terminal opens one (Leo
// 2026-10-21). The page is the pane's dev entry with its browser host, talking JSON-RPC to a
// stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-background-tasks.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-background-tasks: skipping (run `bunx playwright install chromium`)");
    describe.skip("background tasks", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e1";
  const START = Date.UTC(2026, 9, 12, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
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
  const ended = (id: string, command: string, state: string, extra: object = {}): Step => [
    "in",
    "background_task_update",
    update({ sessionUpdate: "background_task_update", taskId: `task-${id}`, toolCallId: id, command, state, ...extra }),
  ];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Start the dev server and the test watcher" }],
    ["mux", "turn_started", {}],
    ...background("bg1", "npm run dev"),
    ...background("bg2", "cargo watch -x test"),
    // acpmux reports a shell that went on in the background as running (claude_stdio `running()`).
    ended("bg2", "cargo watch -x test", "running"),
    ["in", "agent_message_chunk", say("Both are running.")],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "Stop the dev server" }],
    ["mux", "turn_started", {}],
    ended("bg1", "npm run dev", "stopped", { reason: "Stopped by the agent" }),
    // A shell whose Bash row the chat never loaded (an older page, or one Claude moved to the
    // background itself) is known only from how it ended.
    ended("bg3", "pytest -x", "completed", { summary: "Tests passed" }),
    ["in", "agent_message_chunk", say("Dev server stopped.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Dev server",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 2,
    updatedAt: START,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
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
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method) }));
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the notes.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Dev server stopped.").waitFor({ timeout: 25_000 });
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

  test("a background shell ends on its own Ran row; one without its call is one short line", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Dev server stopped.").waitFor();
    // No second row for a shell whose call is in the transcript.
    expect(await page.getByText(/Background task .*npm run dev/).count()).toBe(0);
    // The one whose call is not loaded is noted in the turn it ended, before its reply.
    const note = page.getByText("Background task finished: pytest -x");
    expect(await note.isVisible()).toBe(true);
    const top = (text: string) => page.getByText(text).evaluate((node) => node.getBoundingClientRect().top);
    const at = await note.evaluate((node) => node.getBoundingClientRect().top);
    expect(await top("Stop the dev server")).toBeLessThan(at);
    expect(at).toBeLessThan(await top("Dev server stopped."));
    // The first turn's calls, under its fold: the dev server stopped (a later turn said so), the
    // watcher still runs in the background.
    await page
      .getByRole("button", { name: /^Worked for/ })
      .first()
      .click();
    // Its two calls fold under their run's line too (Debug toggle agentPane.debug.codexToolRuns,
    // on by default): open it to their rows.
    await page.locator("button.cv-tool", { hasText: "Ran 2 commands" }).click();
    const row = (command: string) => page.locator(".cv-tool", { hasText: command }).first();
    await row("npm run dev").waitFor({ timeout: 5_000 });
    const stopped = row("npm run dev").locator(".cv-command__stopped");
    expect(await stopped.textContent()).toBe("Stopped");
    expect(await stopped.getAttribute("title")).toBe("Stopped by the agent");
    expect(await row("cargo watch -x test").locator(".cv-command__bg-state").getAttribute("title")).toBe(
      "Running in background",
    );
    await page.close();
  });

  /// A page whose native host records what the page asks of it (CmuxNextAgentPane's `agentSession`).
  const recordingPage = async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(() => {
      // The dev host installs its native shims on `window.webkit` (dev-host/host.ts); each one is
      // wrapped as it is installed, so the page talks to the dev host as before and every call is
      // recorded. `chat.processTerminal` is answered here, as the App answers it.
      type Call = { method: string; params: Record<string, unknown> };
      const posted: Call[] = [];
      const ask = "chat.processTerminal";
      const wrap = (handlers: Record<string, any> | undefined) => {
        const page = handlers?.cmuxPage;
        if (page && !page.recorded) {
          const post = page.postMessage.bind(page);
          page.postMessage = (message: any) => {
            if (message?.t !== "call") return post(message);
            const method = String(message.op ?? "").replace(/^cmux\.agent\./, "");
            posted.push({ method, params: message.params ?? {} });
            return method === ask
              ? Promise.resolve({ t: "ok", id: message.id, value: { opened: true } })
              : post(message);
          };
          page.recorded = true;
        }
        const session = handlers?.agentSession;
        if (session && !session.recorded) {
          const post = session.postMessage.bind(session);
          session.postMessage = (message: any) => {
            posted.push({ method: message.method, params: message.params ?? {} });
            return message.method === ask ? Promise.resolve({ ok: true, value: { opened: true } }) : post(message);
          };
          session.recorded = true;
        }
      };
      let webkit: any;
      Object.defineProperty(window, "webkit", {
        configurable: true,
        get: () => webkit,
        set: (next) => {
          wrap(next?.messageHandlers);
          webkit = next;
        },
      });
      Object.assign(window, { __posted: posted });
    });
    await page.goto(url(CHAT));
    await page.getByText("Dev server stopped.").waitFor();
    return page;
  };
  const opened = (page: Awaited<ReturnType<typeof recordingPage>>) =>
    page.evaluate(() =>
      ((window as any).__posted as { method: string; params: Record<string, unknown> }[])
        .filter((post) => post.method === "chat.processTerminal")
        .map((post) => post.params),
    );

  test("clicking a background task's end opens it in place; only Open in terminal opens its terminal", async () => {
    const page = await recordingPage();
    const note = page.getByRole("button", { name: /Background task finished: pytest -x/ });
    const top = await note.evaluate((node) => node.getBoundingClientRect().top);
    await note.click();
    expect(await note.getAttribute("aria-expanded")).toBe("true");
    const card = page.locator(`[id="${await note.getAttribute("aria-controls")}"]`);
    await card.waitFor({ timeout: 5_000 });
    expect(await card.locator(".cv-shell__command").textContent()).toBe("$ pytest -x");
    // acpmux's own words on the end.
    expect(await card.locator(".cv-bgtask__detail").textContent()).toBe("Tests passed");
    // The clicked line stays where it was (foldAnchor.ts).
    expect(Math.abs((await note.evaluate((node) => node.getBoundingClientRect().top)) - top)).toBeLessThan(1);
    // Opening it asked the host for nothing.
    expect(await opened(page)).toEqual([]);
    await card.getByRole("button", { name: "Open in terminal" }).click();
    await page.waitForFunction(() =>
      ((window as any).__posted as { method: string }[]).some((post) => post.method === "chat.processTerminal"),
    );
    expect(await opened(page)).toEqual([{ toolCallId: "bg3" }]);
    await page.close();
  });

  type Page = Awaited<ReturnType<typeof recordingPage>>;
  /// Where the chat lists its background tasks: the Inspector's section (the App pushes Debug
  /// Settings `agent.inspector` with the header state; the Inspector opens by default), or, with it
  /// off, the summary card's under the header's Chat summary.
  const surfaces = {
    inspector: {
      open: async (page: Page) => {
        await page.evaluate(() =>
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
        );
        const section = page.locator('aside.acpmux-chat-inspector section[data-section="tasks"]');
        await section.waitFor({ timeout: 5_000 });
        return section;
      },
      row: ".acpmux-chat-inspector-task",
      text: ".acpmux-chat-inspector-task__command",
      // A running row says its time; an ended one how it ended.
      meta: ".acpmux-chat-inspector-task__time, .acpmux-chat-inspector-task__state",
    },
    "summary card": {
      open: async (page: Page) => {
        await page.getByRole("button", { name: "Chat summary" }).click();
        const section = page.getByRole("region", { name: "Background tasks" });
        await section.waitFor({ timeout: 5_000 });
        return section;
      },
      row: ".acpmux-summary-task",
      text: ".acpmux-summary-text",
      meta: ".acpmux-summary-meta",
    },
  };

  for (const [name, surface] of Object.entries(surfaces)) {
    test(`clicking a background task in the ${name} opens its terminal, a running one included`, async () => {
      const page = await recordingPage();
      const section = await surface.open(page);
      await section.getByRole("button", { name: /cargo watch -x test/ }).click();
      await page.waitForFunction(() =>
        ((window as any).__posted as { method: string }[]).some((post) => post.method === "chat.processTerminal"),
      );
      expect(await opened(page)).toEqual([{ toolCallId: "bg2" }]);
      await page.close();
    });

    test(`the ${name} lists the chat's background tasks: running ones first, the finished folded`, async () => {
      const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
      await page.goto(url(CHAT));
      await page.getByText("Dev server stopped.").waitFor();
      const section = await surface.open(page);
      const rows = () =>
        section
          .locator(surface.row)
          .evaluateAll(
            (items, { text, meta }) =>
              items.map((item) => [item.querySelector(text)?.textContent, item.querySelector(meta)?.textContent]),
            { text: surface.text, meta: surface.meta },
          );
      // The running one says how long it has run, with no Stop (the registry lists nothing).
      const running = await rows();
      expect(running[0]![0]).toBe("cargo watch -x test");
      expect(running[0]![1]).toMatch(/^\d+[smh]/);
      expect(await section.locator("button.acpmux-chat-inspector-stop").count()).toBe(0);
      if (name === "summary card") {
        // The summary card keeps the finished ones as cards under it, folded only past five
        // (49acdd1d589d: a finished task never hides behind a count).
        expect(running.slice(1)).toEqual([
          ["npm run dev", "Stopped"],
          ["pytest -x", "Finished"],
        ]);
        expect(await section.locator(".acpmux-summary-finished").count()).toBe(0);
        await page.close();
        return;
      }
      // The Inspector's ended ones wait behind one row.
      expect(running.length).toBe(1);
      const finished = section.getByRole("button", { name: "2 finished" });
      await finished.click();
      expect(await finished.getAttribute("aria-expanded")).toBe("true");
      expect((await rows()).slice(1)).toEqual([
        ["npm run dev", "Stopped"],
        ["pytest -x", "Finished"],
      ]);
      await page.close();
    });
  }
});
