// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Jump to new sits inside the transcript, below the pane's tab row
// (https://github.com/manaflow-ai/cmux/issues/40021). A pane with several tabs draws its tab row as
// its own band at the top of the agent stage, above the scroller; Jump to new is placed over the
// transcript's top, so it must start below that band, never on the tab strip beside the tab titles.
// A one-tab pane's transcript runs up under its row (`topInset`), and the pill still clears the row.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon whose chat has turns that ended since the person last looked.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-since-jump-tab-row.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-since-jump-tab-row: skipping (run `bunx playwright install chromium`)");
    describe.skip("since jump tab row", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000040c1";
  const START = Date.UTC(2026, 10, 9, 9, 0, 0);
  const TURNS = 24;
  const LAST = `Reply ${TURNS}: the last turn while you were away.`;
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [];
  for (let turn = 1; turn <= TURNS; turn++) {
    const text =
      turn === TURNS
        ? LAST
        : `Reply ${turn}: ${"a long paragraph that keeps the transcript taller than the pane. ".repeat(6)}`;
    steps.push(
      ["mux", "user_message", { text: `Step ${turn}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    );
  }
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  // The person saw the first turn; every turn after it ended while they were away.
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Since jump",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: TURNS,
    updatedAt: START,
    unread: true,
    unreadTurns: TURNS - 1,
    seenSeq: 4,
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
    // again if it stalls, so the tests time only the pane.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText(LAST).waitFor({ timeout: 25_000 });
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

  type Bridge = { applyTabRow?(row: unknown): void };

  async function openChat(row: Record<string, unknown>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText(LAST).waitFor();
    await page.waitForFunction(() => Boolean((window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge?.applyTabRow));
    await page.evaluate(() => {
      window.cmuxAcpmuxActions!["pane.tabRowTools"] = async () => null;
    });
    await page.evaluate((row) => (window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge!.applyTabRow!(row), row);
    await page.locator(".acpmux-header[data-tab-row]").waitFor();
    await page.locator(".acpmux-since-jump").waitFor({ state: "attached" });
    return page;
  }

  /// Where Jump to new and the tab row are, after the row's layout has painted.
  const placement = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      const row = document.querySelector<HTMLElement>(".acpmux-header[data-tab-row]")!.getBoundingClientRect();
      const pill = document.querySelector<HTMLElement>(".acpmux-since-jump")!.getBoundingClientRect();
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return {
        rowTop: Math.round(row.top),
        rowBottom: Math.round(row.bottom),
        scrollerBottom: Math.round(scroller.bottom),
        pillTop: Math.round(pill.top),
        pillBottom: Math.round(pill.bottom),
        scrollerTop: Math.round(scroller.top),
      };
    });

  test("in a pane with several tabs, Jump to new sits in the transcript below the tab row", async () => {
    const page = await openChat({ height: 32, trailingInset: 40, soloTab: false });
    const at = await placement(page);
    // The row is a band: the transcript starts under it, and so does the pill over the transcript.
    expect(at.scrollerTop).toBeGreaterThanOrEqual(at.rowBottom);
    expect(at.pillTop).toBeGreaterThanOrEqual(at.rowBottom);
    expect(at.pillTop).toBeGreaterThanOrEqual(at.scrollerTop);
    await page.close();
  });

  test("as tabs open and close and the row resizes, Jump to new never draws over the tab row", async () => {
    // https://github.com/manaflow-ai/cmux/issues/40065: the pill sat over the tab strip's + beside a tab.
    // Each change of the row (a second tab, the last tab closed, a taller row) moves the transcript's
    // top under it; the pill follows, inside the transcript, below the row's bottom.
    const page = await openChat({ height: 32, trailingInset: 40, soloTab: true });
    const rows = [
      { height: 32, trailingInset: 40, soloTab: false },
      { height: 32, trailingInset: 40, soloTab: true },
      { height: 44, trailingInset: 40, soloTab: true },
      { height: 44, trailingInset: 40, soloTab: false },
      { height: 28, trailingInset: 40, soloTab: false },
      { height: 28, trailingInset: 40, soloTab: true },
    ];
    for (const row of rows) {
      await page.evaluate((row) => (window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge!.applyTabRow!(row), row);
      const at = await placement(page);
      const where = `${JSON.stringify(row)} -> ${JSON.stringify(at)}`;
      expect(at.rowBottom - at.rowTop, where).toBe(row.height);
      expect(at.pillTop, where).toBeGreaterThanOrEqual(at.rowBottom);
      expect(at.pillBottom, where).toBeLessThanOrEqual(at.scrollerBottom);
      if (!row.soloTab) expect(at.pillTop, where).toBeGreaterThanOrEqual(at.scrollerTop);
    }
    await page.close();
  });

  test("in a one-tab pane, Jump to new still clears the row the transcript runs under", async () => {
    const page = await openChat({ height: 32, trailingInset: 40, soloTab: true });
    const at = await placement(page);
    expect(at.pillTop).toBeGreaterThanOrEqual(at.rowBottom);
    await page.close();
  });
});
