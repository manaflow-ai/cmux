// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// A chat's background shells (cx-ncc.84, Claude parity). Claude's Bash calls that run in the
// background end with acpmux's `background_task_update`. The transcript notes each end where it
// happened ("Background task stopped · <reason>: <command>"), and the header's summary lists the
// chat's background tasks with how each stands. A click on either opens the task's terminal
// (`chat.processTerminal`, background-task-terminal-DESIGN.md). The page is the pane's dev entry with its browser
// host, talking JSON-RPC to a stand-in acpmux daemon.
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

  test("a background shell's end is noted where it happened", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Dev server stopped.").waitFor();
    const note = page.getByText("Background task stopped · Stopped by the agent: npm run dev");
    expect(await note.isVisible()).toBe(true);
    // In the turn that stopped it, before its reply.
    const top = (text: string) => page.getByText(text).evaluate((node) => node.getBoundingClientRect().top);
    const at = await note.evaluate((node) => node.getBoundingClientRect().top);
    expect(await top("Stop the dev server")).toBeLessThan(at);
    expect(at).toBeLessThan(await top("Dev server stopped."));
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

  test("clicking a background task's end opens its terminal beside the chat", async () => {
    const page = await recordingPage();
    const note = page.getByRole("button", { name: /Stopped by the agent: npm run dev/ });
    expect(await note.getAttribute("title")).toBe("Show output");
    await note.click();
    await page.waitForFunction(() =>
      ((window as any).__posted as { method: string }[]).some((post) => post.method === "chat.processTerminal"),
    );
    expect(await opened(page)).toEqual([{ toolCallId: "bg1" }]);
    await page.close();
  });

  test("clicking a background task in the summary opens its terminal, a running one included", async () => {
    const page = await recordingPage();
    await page.getByRole("button", { name: "Thread details" }).click();
    const section = page.getByRole("region", { name: "Background tasks" });
    await section.waitFor({ timeout: 5_000 });
    await section.getByRole("button", { name: /cargo watch -x test/ }).click();
    await page.waitForFunction(() =>
      ((window as any).__posted as { method: string }[]).some((post) => post.method === "chat.processTerminal"),
    );
    expect(await opened(page)).toEqual([{ toolCallId: "bg2" }]);
    await page.close();
  });

  test("the summary lists the chat's background tasks and how each stands", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Dev server stopped.").waitFor();
    await page.getByRole("button", { name: "Thread details" }).click();
    const section = page.getByRole("region", { name: "Background tasks" });
    await section.waitFor({ timeout: 5_000 });
    const rows = await section
      .locator(".acpmux-summary-row")
      .evaluateAll((items) =>
        items.map((item) => [
          item.querySelector(".acpmux-summary-text")?.textContent,
          item.querySelector(".acpmux-summary-meta")?.textContent,
        ]),
      );
    expect(rows).toEqual([
      ["npm run dev", "Stopped"],
      ["cargo watch -x test", "Running"],
      ["pytest -x", "Finished"],
    ]);
    await page.close();
  });
});
