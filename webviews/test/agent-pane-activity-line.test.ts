// l10n-allow-file: test fixture prompts, todo items and tool titles, not shipped UI.
// The activity line in the real agent pane (cx-ncc.102, Debug Settings `agent.sessionStatus`): with
// the toggle on, a running turn with a todo list shows one line under the list naming the running
// edit by its file name and ticking the turn's time, and no "Working for" status. With the toggle
// off the pane draws as before. The page is the pane's dev entry with its browser host, talking
// JSON-RPC to a stand-in acpmux daemon; the toggle goes in as the app sends it
// (`cmuxAcpmuxBridge.applySessionStatus`).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-activity-line.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-activity-line: skipping (run `bunx playwright install chromium`)");
    describe.skip("activity line", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LIVE = "0190a000-0000-7000-8000-0000000000b1";
  // The turn started a minute ago, so its clock reads past a minute.
  const START = Date.now() - 60_000;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const todo = (content: string, status: string) => ({ content, status, priority: "medium" });
  const file = "/home/dev/storefront/src/components/ProductGrid.module.css";
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Fix the layout shift on the product grid" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say("I'll reserve space in the grid.")],
    [
      "in",
      "plan",
      update({
        sessionUpdate: "plan",
        entries: [todo("Add image dimensions", "completed"), todo("Reserve space in the grid", "in_progress")],
      }),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "edit-1",
        title: `Edit ${file}`,
        kind: "edit",
        status: "in_progress",
        locations: [{ path: file }],
      }),
    ],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: LIVE,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: LIVE,
    cwd: "/home/dev/storefront",
    title: "Product grid",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
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
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${LIVE}`;
  };
  const open = async (statusOn: boolean): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url());
    await page.locator(".cv-plan").waitFor();
    await page.evaluate(
      (on) =>
        (
          window as { cmuxAcpmuxBridge?: { applySessionStatus?(on: boolean): void } }
        ).cmuxAcpmuxBridge?.applySessionStatus?.(on),
      statusOn,
    );
    return page;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
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
    // again if it stalls, so the tests time only the line.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.locator(".cv-plan").waitFor({ timeout: 25_000 });
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

  test("with the toggle on, the line under the todo list names the running edit and ticks the turn's time", async () => {
    const page = await open(true);
    const line = page.locator(".cv-activity");
    await line.waitFor();
    expect(await line.locator(".cv-activity__label").textContent()).toBe("Edit ProductGrid.module.css");
    expect(await line.locator(".cv-activity__time").textContent()).toMatch(/^1m( \d+s)?$/);
    // It takes the "Working for" status's place, under the list.
    expect(await page.getByText(/^Working for/).count()).toBe(0);
    const top = (selector: string) => page.locator(selector).evaluate((node) => node.getBoundingClientRect().top);
    expect(await top(".cv-plan")).toBeLessThan(await top(".cv-activity"));
    const first = await line.locator(".cv-activity__time").textContent();
    await page.waitForFunction(
      (before) => document.querySelector(".cv-activity__time")?.textContent !== before,
      first,
      { timeout: 5_000 },
    );
    await page.close();
  });

  test("with the toggle off, the pane draws no activity line and keeps the running status line", async () => {
    const page = await open(false);
    // The turn's one live line at its bottom (the Codex-style turn, Thinking.tsx), not the
    // activity line.
    await page.locator(".cv-worked.is-below").waitFor();
    expect(await page.locator(".cv-activity").count()).toBe(0);
    await page.close();
  });
});
