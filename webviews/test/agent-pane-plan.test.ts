// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The agent's todo list in the real agent pane (cx-ncc.80, Claude parity): Claude's TodoWrite (an
// ACP `plan` update through acpmux; Codex sends `plan` itself) draws as a checklist, not a muted
// line, and a turn's later updates redraw its one list in place. Each item says its state to a
// screen reader, and the TodoWrite tool calls behind the list draw no rows of their own. The page
// is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-plan.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-plan: skipping (run `bunx playwright install chromium`)");
    describe.skip("plan", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000a1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const todo = (content: string, status: string) => ({ content, status, priority: "medium" });
  const plan = (...entries: object[]) => update({ sessionUpdate: "plan", entries });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// Claude's TodoWrite tool call, which acpmux sends right after the plan it wrote.
  const todoWrite = (id: string): Step[] => [
    [
      "in",
      "tool_call",
      update({ sessionUpdate: "tool_call", toolCallId: id, title: "TodoWrite", kind: "other", status: "in_progress" }),
    ],
    ["in", "tool_call_update", update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" })],
  ];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Add retry, cover it, update the docs" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "plan",
      plan(
        todo("Add retry to the uploader", "in_progress"),
        todo("Cover it with a test", "pending"),
        todo("Update the docs", "pending"),
      ),
    ],
    ...todoWrite("todo-1"),
    ["in", "agent_message_chunk", say("Retry added.")],
    [
      "in",
      "plan",
      plan(
        todo("Add retry to the uploader", "completed"),
        todo("Cover it with a test", "completed"),
        todo("Update the docs", "in_progress"),
      ),
    ],
    ...todoWrite("todo-2"),
    ["in", "agent_message_chunk", say(" All three done.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  // A turn still running: its tool calls show outside any fold.
  const LIVE = "0190a000-0000-7000-8000-0000000000a2";
  const liveSteps: Step[] = [
    ["mux", "user_message", { text: "Add retry and cover it" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("I'll track this.")],
    ["in", "plan", plan(todo("Add retry to the uploader", "in_progress"), todo("Cover it with a test", "pending"))],
    ...todoWrite("todo-live"),
    ["in", "agent_message_chunk", say("Adding retry now.")],
  ];
  const record = (sessionId: string, list: Step[]) =>
    list.map(([dir, kind, msg], index) => ({ sessionId, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
  const events = record(CHAT, steps);
  const liveEvents = record(LIVE, liveSteps);
  const entry = (sessionId: string, status: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Uploader retry",
    harness: "claude",
    family: "claude",
    status,
    turnCount: 1,
    updatedAt: START,
  });
  const session = entry(CHAT, "idle");
  const live = entry(LIVE, "running");

  function answer(method: string, params: Record<string, any> = {}): unknown {
    const [chat, chatEvents] = params.sessionId === LIVE ? [live, liveEvents] : [session, events];
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session, live] };
      case "_acpmux/attach":
        return { session: chat, lastSeq: chatEvents.length, events: chatEvents };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: chatEvents.length };
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the checklist.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("All three done.").waitFor({ timeout: 25_000 });
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

  test("a turn's todo list draws as one checklist that follows the latest update", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("All three done.").waitFor();
    const lists = await page.evaluate(() =>
      [...document.querySelectorAll(".cv-plan")].map((list) => ({
        // Heard, not drawn, like each item's state: the marks show the progress.
        progress: list.querySelector(".cv-plan__progress")?.textContent,
        items: [...list.querySelectorAll(".cv-plan__item")].map((item) => [
          item.querySelector(".cv-plan__text")?.textContent,
          item.getAttribute("data-status"),
          // What a screen reader hears for the item's state (the marks are drawn only).
          item.querySelector(".cv-plan__state")?.textContent,
        ]),
      })),
    );
    // Heard, not drawn: the state word takes no room beside the item.
    expect(
      await page.evaluate(() =>
        [...document.querySelectorAll(".cv-plan__state")].every((node) => node.getBoundingClientRect().width <= 1),
      ),
    ).toBe(true);
    expect(lists).toEqual([
      {
        progress: "2 of 3 tasks done",
        items: [
          ["Add retry to the uploader", "completed", "Done"],
          ["Cover it with a test", "completed", "Done"],
          ["Update the docs", "in_progress", "In progress"],
        ],
      },
    ]);

    // Claude desktop's card: the marks carry the state, with no strike-through or bold, and the
    // step the agent left in progress stops spinning once its turn has ended.
    expect(
      await page.evaluate(() =>
        [...document.querySelectorAll(".cv-plan__item")].map((item) => {
          const style = getComputedStyle(item);
          return [style.textDecorationLine, style.fontWeight];
        }),
      ),
    ).toEqual([
      ["none", "400"],
      ["none", "400"],
      ["none", "400"],
    ]);
    expect(
      await page
        .locator('.cv-plan__item[data-status="in_progress"] .cv-plan__mark')
        .evaluate((mark) => getComputedStyle(mark).animationName),
    ).toBe("none");
    expect(await page.locator(".cv-plan").evaluate((list) => getComputedStyle(list).boxShadow)).not.toBe("none");

    await page.close();
  });
  test("while the turn runs, the step in progress spins and the next one waits as a dashed circle", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(LIVE));
    await page.getByText("Adding retry now.").waitFor();
    const mark = (status: string) =>
      page.locator(`.cv-plan__item[data-status="${status}"] .cv-plan__mark`).evaluate((node) => {
        const style = getComputedStyle(node);
        return { animation: style.animationName, border: style.borderTopStyle };
      });
    // Every step shows: the row is not held to the composer Plan toggle's 28px (.acpmux-plan).
    expect(
      await page.evaluate(() => {
        const row = document.querySelector(".acpmux-row:has(.cv-plan)")!.getBoundingClientRect();
        return [...document.querySelectorAll(".cv-plan__item")].every((item) => {
          const box = item.getBoundingClientRect();
          return box.top >= row.top && box.bottom <= row.bottom;
        });
      }),
    ).toBe(true);
    expect((await mark("in_progress")).animation).toBe("cmux-spin");
    expect(await mark("pending")).toEqual({ animation: "none", border: "dashed" });
    await page.close();
  });
  test("while the turn runs, the checklist stands for its TodoWrite calls", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(LIVE));
    await page.getByText("Adding retry now.").waitFor();
    expect(await page.locator(".cv-plan__item").count()).toBe(2);
    expect(await page.getByText("TodoWrite").count()).toBe(0);
    // The checklist keeps its place between the text before it and the text after it.
    const top = (text: string) => page.getByText(text).evaluate((node) => node.getBoundingClientRect().top);
    const list = await page.locator(".cv-plan").evaluate((node) => node.getBoundingClientRect().top);
    expect(await top("I'll track this.")).toBeLessThan(list);
    expect(list).toBeLessThan(await top("Adding retry now."));
    await page.close();
  });
});
