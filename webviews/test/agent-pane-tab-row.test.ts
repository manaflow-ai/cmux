// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// One row on top (the chrome.tabs.rowTools Debug setting; Leo 2026-10-14, "why is there even a top
// bar"): while the App offers the pane's tab row (`tabRow {height, trailingInset}`), the chat header
// is that row's height, shows its tools at its right end left of the pane's own "…", and reports
// their width (`pane.tabRowTools`) so the App narrows the tabs; 0 once the row ends. Without an
// offer the header is its own row, as before, and reports nothing. The page is the pane's dev entry
// with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tab-row.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-tab-row: skipping (run `bunx playwright install chromium`)");
    describe.skip("tab row", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const REPLY = "The header tools share the tab row.";
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Put the tools in the tab row" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
        },
      },
    ],
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
    title: "Tab row",
    harness: "claude",
    family: "claude",
    status: "idle",
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
    // again if it stalls, so the test times only the header.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText(REPLY).waitFor({ timeout: 25_000 });
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
  type Recorder = { __tabRowCalls?: unknown[] };

  /// Opens the chat and records its `pane.tabRowTools` calls in `window.__tabRowCalls`.
  async function openChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText(REPLY).waitFor();
    await page.waitForFunction(
      () =>
        Boolean((window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge?.applyTabRow) &&
        Boolean(window.cmuxAcpmuxActions),
    );
    await page.evaluate(() => {
      const calls: unknown[] = [];
      (window as Recorder).__tabRowCalls = calls;
      window.cmuxAcpmuxActions!["pane.tabRowTools"] = async (params) => {
        calls.push(params);
        return null;
      };
    });
    return page;
  }

  const offer = (page: Page, row: unknown) =>
    page.evaluate((row) => (window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge!.applyTabRow!(row), row);

  /// The header's height and mode, and how far its tools end from the page's right edge.
  const header = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      const header = document.querySelector<HTMLElement>(".acpmux-header")!;
      const tools = header.querySelector(".acpmux-handoff-header-tools")!.getBoundingClientRect();
      return {
        height: Math.round(header.getBoundingClientRect().height),
        tabRow: header.hasAttribute("data-tab-row"),
        inset: Math.round(window.innerWidth - tools.right),
      };
    });
  const calls = (page: Page) => page.evaluate(() => [...((window as Recorder).__tabRowCalls ?? [])]);

  test("without an offered row the header is its own row and reports nothing", async () => {
    const page = await openChat();
    const before = await header(page);
    // Its own row is the compact toolbar's 28px (5b181c2efb9f, --acpmux-header-height).
    expect(before).toMatchObject({ tabRow: false, height: 28, inset: 8 });
    // A row of height 0 (the setting is off, or the pane's tabs are hidden) changes nothing.
    await offer(page, { height: 0, trailingInset: 40 });
    // header() reads after two painted frames: the row, had it applied, and any report are in by then.
    expect(await header(page)).toEqual(before);
    expect(await calls(page)).toEqual([]);
    await page.close();
  });

  test("an offered row puts the tools at its right end and reports their width", async () => {
    const page = await openChat();
    await offer(page, { height: 28, trailingInset: 40 });
    await page.locator(".acpmux-header[data-tab-row]").waitFor();
    expect(await header(page)).toEqual({ tabRow: true, height: 28, inset: 40 });
    await page.waitForFunction(() => ((window as Recorder).__tabRowCalls ?? []).length > 0);
    const reported = (await calls(page)) as { width: number }[];
    const tools = await page.evaluate(() =>
      Math.round(document.querySelector(".acpmux-handoff-header-tools")!.getBoundingClientRect().width),
    );
    expect(tools).toBeGreaterThan(0);
    // The tools' width and the gap the tabs keep from them.
    expect(reported.at(-1)).toEqual({ width: tools + 4 });
    // Only the tools take clicks: the row's left part is the App's tabs.
    expect(await page.evaluate(() => getComputedStyle(document.querySelector(".acpmux-header")!).pointerEvents)).toBe(
      "none",
    );
    // The row ends (the setting turned off): the header's own row again, and the tabs get the width back.
    await offer(page, { height: 0, trailingInset: 0 });
    await page.waitForFunction(() => !document.querySelector(".acpmux-header[data-tab-row]"));
    expect(await header(page)).toMatchObject({ tabRow: false, height: 28, inset: 8 });
    await page.waitForFunction(() => {
      const last = ((window as Recorder).__tabRowCalls ?? []).at(-1) as { width?: number } | undefined;
      return last?.width === 0;
    });
    await page.close();
  });

  test("the same row offered again (a reloaded page's handshake) gets the width reported again", async () => {
    const page = await openChat();
    await offer(page, { height: 28, trailingInset: 40 });
    await page.waitForFunction(() => ((window as Recorder).__tabRowCalls ?? []).length > 0);
    const first = ((await calls(page)) as { width: number }[]).at(-1);
    expect(first?.width).toBeGreaterThan(0);
    // The App forgot the width (its page said ready again) and offers the row it offered before.
    await page.evaluate(() => ((window as Recorder).__tabRowCalls!.length = 0));
    await offer(page, { height: 28, trailingInset: 40 });
    await page.waitForFunction(() => ((window as Recorder).__tabRowCalls ?? []).length > 0);
    expect(((await calls(page)) as { width: number }[]).at(-1)).toEqual(first);
    await page.close();
  });
});
