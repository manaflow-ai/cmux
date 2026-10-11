// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The agent's todo list in the real agent pane (cx-ncc.80, Claude parity): Claude's TodoWrite (an
// ACP `plan` update through acpmux; Codex sends `plan` itself) draws as a checklist, not a muted
// line, and a turn's later updates redraw its one list in place. The page is the pane's dev entry
// with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

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
    ["in", "agent_message_chunk", say(" All three done.")],
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
    title: "Uploader retry",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };

  function answer(method: string, params: Record<string, any>): unknown {
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
        heading: list.querySelector(".cv-plan__heading")?.textContent,
        items: [...list.querySelectorAll(".cv-plan__item")].map((item) => [
          item.textContent,
          item.getAttribute("data-status"),
        ]),
      })),
    );
    expect(lists).toEqual([
      {
        heading: "2 of 3 tasks done",
        items: [
          ["Add retry to the uploader", "completed"],
          ["Cover it with a test", "completed"],
          ["Update the docs", "in_progress"],
        ],
      },
    ]);
    await page.close();
  });
});
