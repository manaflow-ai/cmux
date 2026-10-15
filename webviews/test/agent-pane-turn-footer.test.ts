// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reply's footer is one quiet row (Leo 2026-10-13, cmux NEXT): Worked for and the time as muted
// text, then Copy, Retry and Branch, at the column's right edge where a prompt's Copy and Edit sit
// under its bubble. It shows for the last turn, and for another turn while the reader points at
// any of it.
//
// Before: every reply's footer showed at rest, at the column's left edge, with the time after the
// buttons.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-turn-footer.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-turn-footer: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn footer", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000f3";
  const START = Date.UTC(2026, 9, 13, 19, 0, 0);
  const chunk = (text: string) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Is the hosted test run done?", promptId: "p-1" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", chunk("Not yet: the hosted test run is still queued.")],
    ["mux", "turn_result", { status: "completed" }],
    ["mux", "user_message", { text: "And the PR checks?", promptId: "p-2" }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", chunk("Meanwhile the PR checks are still waiting on the hosted run.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 9000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Hosted run",
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
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  const open = async (experiments?: Record<string, string>): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    if (experiments) {
      await page.addInitScript((arms) => {
        (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = arms;
      }, experiments);
    }
    await page.goto(url());
    await page.getByText("Meanwhile the PR checks").waitFor();
    await page.mouse.move(0, 0);
    await page.waitForTimeout(300);
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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Meanwhile the PR checks").waitFor({ timeout: 25_000 });
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

  /// Each footer's opacity as drawn, first turn first.
  const footers = (page: Page) =>
    page.locator(".cv-turn-actions").evaluateAll((nodes) => nodes.map((node) => getComputedStyle(node).opacity));

  test("only the last turn's footer shows at rest; pointing at an earlier reply shows its own", async () => {
    const page = await open();
    expect(await footers(page)).toEqual(["0", "1"]);
    await page.getByText("Not yet: the hosted test run").hover();
    await page.waitForTimeout(250);
    expect(await footers(page)).toEqual(["1", "1"]);
    await page.mouse.move(0, 0);
    await page.waitForTimeout(250);
    expect(await footers(page)).toEqual(["0", "1"]);
    await page.close();
  });

  test("the footer is one row at the column's right edge: muted Worked for and time, then the actions", async () => {
    // The `hover-actions` experiment's "all" arm keeps a plain prompt's Copy, so the prompt has a
    // last button to line the reply's actions up with.
    const page = await open({ "hover-actions": "all" });
    const footer = await page.evaluate(() => {
      const actions = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions")].at(-1)!;
      const row = actions.closest(".acpmux-row")!.getBoundingClientRect();
      const box = (selector: string) => actions.querySelector(selector)!.getBoundingClientRect();
      // The last button of each row of actions: a prompt's (Copy, Edit) and the reply's.
      const prompt = [...document.querySelectorAll<HTMLElement>(".cv-user__actions button")]
        .at(-1)!
        .getBoundingClientRect();
      const summary = box(".cv-turn-summary");
      const time = box(".cv-turn-time");
      const group = box(".cv-turn-action-group");
      const last = [...actions.querySelectorAll("button")].at(-1)!.getBoundingClientRect();
      return {
        // The actions end where a prompt's do, at the column's right edge.
        actionsRight: Math.round(row.right - last.right),
        promptRight: Math.round(row.right - prompt.right),
        order: summary.right <= time.left && time.right <= group.left,
        oneRow: Math.abs(summary.top + summary.height / 2 - (group.top + group.height / 2)) <= 2,
      };
    });
    expect(footer).toEqual({
      actionsRight: footer.promptRight,
      promptRight: footer.promptRight,
      order: true,
      oneRow: true,
    });
    expect(footer.promptRight).toBeLessThanOrEqual(2);
    await page.close();
  });
});
