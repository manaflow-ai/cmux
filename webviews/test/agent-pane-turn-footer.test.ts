// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A reply's footer is one quiet row, as Claude Code desktop's (Leo 2026-10-20): Copy, Fork, Pin and
// Read aloud, then the reply's age, at the column's left edge under the reply (the Debug menu can
// move it right). It shows only while the reader points at the turn (or a key reaches it), the last
// turn's too, and keeps its height while hidden.
//
// Before: every reply's footer showed at rest, with the time after the buttons.
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
    // The footers' fade has ended: every footer is fully shown or fully hidden.
    await page.waitForFunction(() =>
      [...document.querySelectorAll(".cv-turn-actions")].every((node) =>
        ["0", "1"].includes(getComputedStyle(node).opacity),
      ),
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
  /// Waits for the footers to be drawn at `opacities` (a fade runs in between), then reads them.
  const footersReach = async (page: Page, opacities: string[]) => {
    await page
      .waitForFunction(
        (want) =>
          JSON.stringify(
            [...document.querySelectorAll(".cv-turn-actions")].map((node) => getComputedStyle(node).opacity),
          ) === JSON.stringify(want),
        opacities,
        { timeout: 5_000 },
      )
      .catch(() => undefined);
    return footers(page);
  };

  test("no footer shows at rest; pointing at a reply shows its own only", async () => {
    const page = await open();
    expect(await footers(page)).toEqual(["0", "0"]);
    await page.getByText("Not yet: the hosted test run").hover();
    expect(await footersReach(page, ["1", "0"])).toEqual(["1", "0"]);
    await page.mouse.move(0, 0);
    expect(await footersReach(page, ["0", "0"])).toEqual(["0", "0"]);
    await page.close();
  });

  test("the footer is one row at the column's left edge: muted Worked for, the actions, then the age", async () => {
    const page = await open();
    const footer = await page.evaluate(() => {
      const actions = [...document.querySelectorAll<HTMLElement>(".cv-turn-actions")].at(-1)!;
      const row = actions.closest(".acpmux-row")!.getBoundingClientRect();
      const box = (selector: string) => actions.querySelector(selector)!.getBoundingClientRect();
      const summary = box(".cv-turn-summary");
      const time = box(".cv-turn-time");
      const group = box(".cv-turn-action-group");
      return {
        // The row starts at the reply's left edge.
        startsLeft: summary.left - row.left <= 4,
        order: summary.right <= group.left && group.right <= time.left,
        oneRow: Math.abs(summary.top + summary.height / 2 - (group.top + group.height / 2)) <= 2,
      };
    });
    expect(footer).toEqual({ startsLeft: true, order: true, oneRow: true });
    await page.close();
  });
});
