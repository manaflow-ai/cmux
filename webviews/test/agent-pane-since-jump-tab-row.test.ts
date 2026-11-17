// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Jump to new sits inside the transcript, below the pane's tab row, at any width and layout
// (https://github.com/manaflow-ai/cmux/issues/40021). A pane with several tabs draws its tab row as
// its own band at the top of the agent stage, above the scroller; Jump to new is placed over the
// transcript's top, so it must start below that band, never on the tab strip beside the tab titles.
// A one-tab pane's transcript runs up under its row (`topInset`), and the pill still clears the row;
// so does a header that is its own row. Each layout runs at a wide, a narrow and a phone-narrow width.
// SINCE_JUMP_SHOTS=<dir> saves the top of each pane as a PNG there.
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

  /// Opens the chat at `width` and offers `row` (no offer: the header is its own row).
  async function openChat(width: number, row?: Record<string, unknown>): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText(LAST).waitFor();
    await page.waitForFunction(() => Boolean((window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge?.applyTabRow));
    await page.evaluate(() => {
      window.cmuxAcpmuxActions!["pane.tabRowTools"] = async () => null;
    });
    if (row) {
      await page.evaluate((row) => (window as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge!.applyTabRow!(row), row);
      await page.locator(".acpmux-header[data-tab-row]").waitFor();
    }
    await page.locator(".acpmux-since-jump[data-shown]").waitFor();
    return page;
  }

  /// Where Jump to new, the header (the tab row when offered) and the transcript are, after the
  /// layout has painted.
  const placement = (page: Page) =>
    page.evaluate(async () => {
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      const box = (selector: string) => {
        const r = document.querySelector<HTMLElement>(selector)!.getBoundingClientRect();
        return { top: r.top, bottom: r.bottom, left: r.left, right: r.right };
      };
      return { header: box(".acpmux-header"), pill: box(".acpmux-since-jump"), scroller: box(".acpmux-scroll") };
    });

  const shots = process.env.SINCE_JUMP_SHOTS;
  const layouts = [
    { name: "a pane with several tabs", slug: "tabs", row: { height: 32, trailingInset: 40, soloTab: false } },
    { name: "a one-tab pane", slug: "solo", row: { height: 32, trailingInset: 40, soloTab: true } },
    { name: "a header of its own (no tab row)", slug: "header", row: undefined },
  ];
  for (const layout of layouts)
    for (const width of [900, 480, 320])
      test(`in ${layout.name} at ${width}px, Jump to new never overlaps the header`, async () => {
        const page = await openChat(width, layout.row);
        if (shots)
          await page.screenshot({
            path: path.join(shots, `since-jump-${layout.slug}-${width}.png`),
            clip: { x: 0, y: 0, width, height: 140 },
          });
        const at = await placement(page);
        // Below the header's bottom edge: no pixel of the pill is on the tab strip or its buttons.
        expect(at.pill.top).toBeGreaterThanOrEqual(at.header.bottom);
        // And over the transcript, not past its top where the transcript is a band below the row.
        if (!layout.row?.soloTab) expect(at.pill.top).toBeGreaterThanOrEqual(at.scroller.top);
        // Inside the pane's width at any width.
        expect(at.pill.left).toBeGreaterThanOrEqual(0);
        expect(at.pill.right).toBeLessThanOrEqual(width);
        await page.close();
      });
});
