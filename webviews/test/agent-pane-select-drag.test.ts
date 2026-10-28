// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag in the agent chat's transcript selects the words under the pointer (user 2026-10-21:
// "I select text but it chooses the text on the line above where my mouse cursor is"). The real
// agent pane (its dev entry and browser host, talking JSON-RPC to a stand-in acpmux daemon) shows
// a reply with one long paragraph; a drag along one of its lines, from the middle of its second word
// to the middle of its fifth, must select text from that line alone. It also checks rows sit where
// the transcript's layout puts them (16 px into the thread).
//
// The app draws the pane in Chromium (CEF) at a page zoom; the root's CSS zoom here is not the same
// path, and the offset did not show at it, so this guards selection and placement rather than
// reproducing the app's bug. Each case runs in Chromium and WebKit; an engine that is not
// installed is skipped.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-select-drag.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-select-drag: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("select drag", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d7";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Backoff",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: Date.now(),
  };
  const REPLY =
    "To pin down the retry, open the log again, click into the text, press the key once, and tell " +
    "me what happened (nothing, or something else). I will check what the app resolved the key to " +
    "while it is still focused there. If it is a real bug, I can fix it in a worktree and open a " +
    "pull request. A client that fails waits a little longer before each retry, and adds a random " +
    "jitter so a crowd of clients does not retry in step.";
  const events = [
    { kind: "user_message", dir: "mux", msg: { text: "so this is expected?", promptId: "p-0" } },
    { kind: "turn_started", dir: "mux", msg: {} },
    {
      kind: "agent_message_chunk",
      dir: "in",
      msg: {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
        },
      },
    },
    { kind: "turn_result", dir: "mux", msg: { status: "completed" } },
  ].map((event, index) => ({ sessionId: SESSION, seq: index + 1, at: Date.now(), ...event }));

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: events.length, events };
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
    await warmViteServer(vite, "/");
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// The reply paragraph's visual lines: each line's box and the words whose middle lies on it.
  const replyLines = (page: Page) =>
    page.evaluate(
      (start) => {
        const paragraph = [...document.querySelectorAll(".acpmux-scroll p")].find((p) =>
          p.textContent?.startsWith(start),
        )!;
        const walker = document.createTreeWalker(paragraph, NodeFilter.SHOW_TEXT);
        const words: { word: string; x: number; y: number; top: number; bottom: number }[] = [];
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const text = node.textContent ?? "";
          for (const match of text.matchAll(/\S+/g)) {
            const range = document.createRange();
            range.setStart(node, match.index);
            range.setEnd(node, match.index + match[0].length);
            const rect = range.getClientRects()[0];
            if (!rect) continue;
            words.push({
              word: match[0],
              x: rect.left + rect.width / 2,
              y: rect.top + rect.height / 2,
              top: rect.top,
              bottom: rect.bottom,
            });
          }
        }
        const lines: (typeof words)[] = [];
        for (const word of words) {
          const line = lines.at(-1);
          if (line && Math.abs(line[0]!.y - word.y) < 2) line.push(word);
          else lines.push([word]);
        }
        return lines;
      },
      REPLY.slice(0, 20),
    );

  // The app shows the pane at a page zoom (`app.uiScale` times the chat's own zoom, about 1.22 in
  // the report); the root's CSS zoom stands in for it. At 1.5, Chromium's CSS zoom left some drags
  // with no selection in CI (runs 39691197367, 39710957162), so the cases stop at 1.25.
  const cases = engines.flatMap(([name]) => [1, 1.25].map((zoom) => [name, zoom] as const));
  test.each(cases)("%s at zoom %p: a drag along a line of a reply selects words on that line", async (name, zoom) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 1000 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText(REPLY.slice(0, 20), { exact: false }).waitFor();
    // Rows sit at their `top` plus the thread's 16 px top padding, where the earlier translate put them.
    const firstRowInset = await page.evaluate(() => {
      const thread = document.querySelector(".acpmux-thread")!.getBoundingClientRect().top;
      return Math.round(document.querySelector(".acpmux-row")!.getBoundingClientRect().top - thread);
    });
    expect(firstRowInset).toBe(16);
    await page.evaluate((zoom) => {
      document.documentElement.style.zoom = String(zoom);
    }, zoom);
    for (let frame = 0; frame < 3; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    const lines = await replyLines(page);
    expect(lines.length).toBeGreaterThanOrEqual(3);
    const results: { line: number; selected: string; expected: string }[] = [];
    for (let index = 1; index < lines.length; index++) {
      const line = lines[index]!;
      // A line's last words can be a short tail; it needs a start word, two whole words and an end.
      if (line.length < 5) continue;
      // From the second word, not the first: a first word of one letter ("I") puts the press on
      // the line's left edge.
      const from = line[1]!;
      const to = line[4]!;
      await page.evaluate(() => window.getSelection()?.removeAllRanges());
      // A fractional exact midpoint can miss Chromium's caret hit-test (notably the word "and" at
      // zoom 1). Floor the press into the word while keeping the release points exact.
      await page.mouse.move(Math.floor(from.x), from.y);
      await page.mouse.down();
      await page.mouse.move((from.x + to.x) / 2, to.y, { steps: 4 });
      await page.mouse.move(to.x, to.y, { steps: 4 });
      await page.mouse.up();
      const selected = (await page.evaluate(() => window.getSelection()?.toString() ?? "")).trim();
      const words = line.map((word) => word.word);
      // The selection runs from inside the second word to inside the fifth: it holds the words
      // between them in full, and nothing from another line.
      const expected = words.slice(2, 4).join(" ");
      const onLine = words.join(" ");
      results.push({
        line: index,
        selected,
        expected:
          onLine.includes(selected) && selected.includes(expected) ? selected : `${expected} (within: ${onLine})`,
      });
    }
    expect(results.length).toBeGreaterThanOrEqual(2);
    expect(results.map(({ line, selected }) => ({ line, selected }))).toEqual(
      results.map(({ line, expected }) => ({ line, selected: expected })),
    );
    await page.close();
  });
});
