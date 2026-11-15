// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A long chat's rows never draw over each other after the pane's width changes (cmux#43975: "a NEXT
// agent chat transcript draws two layers of messages on top of each other: rows overlap and the text
// can't be read"). The chat holds far more rows than the transcript keeps prepared text for
// (model.ts PREPARED_ROWS), each turn with a long reply that wraps to many more lines in a narrow
// pane than in a wide one. The chat opens wide, the pane narrows (a split, a restart that first lays
// the page out at another size), and the reader scrolls up through it, then jumps far up and back.
// At rest at each stop, no two rows in view may cross: each row starts below the one above it.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon. Both engines the app uses; one not installed skips.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-long-chat-width-overlap.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-long-chat-width-overlap: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("long chat width overlap", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-000000043975";
  const TURNS = 160;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "idle",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: TURNS,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>) =>
    events.push({ sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg });
  const SENTENCE =
    "The workspace placement fix is not merged yet, so the final evals and the final test run are still going on the newest head";
  /// A long reply: a heading, paragraphs and bullets that each wrap to several lines in a narrow pane.
  const reply = (turn: number) =>
    [
      `**Before and after numbers ${turn}.** ${SENTENCE}.`,
      ...Array.from({ length: 6 }, (_, item) => `- **Point ${turn}.${item}:** ${SENTENCE} (${turn}, ${item}).`),
      `**Next ${turn}:**`,
      ...Array.from({ length: 4 }, (_, item) => `${item + 1}. ${SENTENCE}, step ${item}.`),
      `Closing ${turn}. ${SENTENCE}.`,
    ].join("\n\n");
  for (let turn = 0; turn < TURNS; turn++) {
    record("mux", "user_message", { text: `Task ${turn}: check the placement`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    for (let step = 0; step < 2; step++) {
      record("in", "agent_message_chunk", chunk(`While the baseline runs, I check step ${step} of ${turn}.`));
      const id = `t-${turn}-${step}`;
      record(
        "in",
        "tool_call",
        update({ sessionUpdate: "tool_call", toolCallId: id, title: "ls", kind: "execute", status: "in_progress", rawInput: { command: "ls" } }),
      );
      record(
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: "a\n" } }],
          rawOutput: { exit_code: 0 },
        }),
      );
    }
    record("in", "agent_message_chunk", chunk(reply(turn)));
    record("mux", "turn_result", { status: "completed" });
  }

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
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
    await warmViteServer(vite, "/", { timeoutMs: 280_000 });
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Crossing = { stop: string; upper: string; lower: string; by: number };
  /// The rows in view, by where they draw: each pair whose upper row's box reaches past the lower
  /// row's top by more than a pixel.
  const crossings = (page: Page, stop: string) =>
    page.evaluate((stop) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      const label = (row: HTMLElement) => (row.textContent ?? "").trim().slice(0, 40);
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row[data-row-id]")]
        .map((row) => ({ row, rect: row.getBoundingClientRect() }))
        .filter(({ rect }) => rect.height > 0.5 && rect.bottom > view.top && rect.top < view.bottom)
        .sort((a, b) => a.rect.top - b.rect.top);
      const out: { stop: string; upper: string; lower: string; by: number }[] = [];
      for (let index = 0; index + 1 < rows.length; index++) {
        const upper = rows[index]!;
        const lower = rows[index + 1]!;
        const by = upper.rect.bottom - lower.rect.top;
        if (by > 1) out.push({ stop, upper: label(upper.row), lower: label(lower.row), by: Math.round(by) });
      }
      return { out, mounted: rows.length };
    }, stop);

  /// Lets the transcript settle: every frame for a while, so measured rows are placed again.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done) => {
          let frames = 0;
          const tick = () => (++frames >= 30 ? done() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
    );

  for (const [name] of engines)
    test(`${name}: a long chat opened wide and narrowed draws no row over another as the reader scrolls`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1600, height: 900 } });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText(`Closing ${TURNS - 1}.`).waitFor({ timeout: 60_000 });
      await settle(page);
      const found: Crossing[] = [];
      const check = async (stop: string) => {
        await settle(page);
        const { out, mounted } = await crossings(page, stop);
        expect(mounted).toBeGreaterThan(1);
        found.push(...out);
      };
      await check("wide, at the latest row");
      await page.setViewportSize({ width: 620, height: 900 });
      await check("narrowed, at the latest row");
      await page.mouse.move(300, 400);
      for (let step = 1; step <= 6; step++) {
        await page.mouse.wheel(0, -1400);
        await check(`narrowed, scrolled up ${step}`);
      }
      for (const share of [0.5, 0.2, 0.8]) {
        await page.evaluate((share) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = (scroller.scrollHeight - scroller.clientHeight) * share;
        }, share);
        await check(`narrowed, jumped to ${share}`);
        await page.mouse.wheel(0, 900);
        await check(`narrowed, jumped to ${share} and scrolled down`);
      }
      console.log(`WIDTH_OVERLAP_REPORT ${JSON.stringify({ engine: name, crossings: found.slice(0, 12), total: found.length })}`);
      await page.close();
      expect(found.slice(0, 6)).toEqual([]);
    });
});
