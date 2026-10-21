// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A drag in the agent chat's transcript selects the words under the pointer (user 2026-10-21:
// "I select text but it chooses the text on the line above where my mouse cursor is"). The real
// agent pane (its dev entry and browser host, talking JSON-RPC to a stand-in acpmux daemon) shows
// a reply with one long paragraph; a drag along one of its lines, from the middle of its first word
// to the middle of a later word on the same line, must select text from that line alone.
//
// The app draws the pane in WebKit, so each case runs in WebKit and Chromium; an engine that is
// not installed is skipped.
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
        params: { sessionId: "agent-1", update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } } },
      },
    },
    { kind: "turn_result", dir: "mux", msg: { status: "completed" } },
  ].map((event, index) => ({ sessionId: SESSION, seq: index + 1, at: Date.now(), ...event }));

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
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
    page.evaluate((start) => {
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
    }, REPLY.slice(0, 20));

  test.each(engines.map(([name]) => name))(
    "%s: a drag along a line of a reply selects words on that line",
    async (name) => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
      await page.getByText(REPLY.slice(0, 20), { exact: false }).waitFor();
      for (let frame = 0; frame < 3; frame++) await page.evaluate(() => window.cmuxPaintFrame());
      const lines = await replyLines(page);
      expect(lines.length).toBeGreaterThanOrEqual(3);
      const results: { line: number; selected: string; expected: string }[] = [];
      for (let index = 1; index < lines.length; index++) {
        const line = lines[index]!;
        const from = line[0]!;
        const to = line[Math.min(3, line.length - 1)]!;
        await page.evaluate(() => window.getSelection()?.removeAllRanges());
        await page.mouse.move(from.x, from.y);
        await page.mouse.down();
        await page.mouse.move((from.x + to.x) / 2, to.y, { steps: 4 });
        await page.mouse.move(to.x, to.y, { steps: 4 });
        await page.mouse.up();
        const selected = (await page.evaluate(() => window.getSelection()?.toString() ?? "")).trim();
        const words = line.map((word) => word.word);
        // The selection runs from inside the first word to inside the fourth: it holds the words
        // between them in full, and nothing from another line.
        const expected = words.slice(1, Math.min(3, words.length - 1)).join(" ");
        const onLine = words.join(" ");
        results.push({ line: index, selected, expected: onLine.includes(selected) && selected.includes(expected) ? selected : `${expected} (within: ${onLine})` });
      }
      expect(results.map(({ line, selected }) => ({ line, selected }))).toEqual(
        results.map(({ line, expected }) => ({ line, selected: expected })),
      );
      await page.close();
    },
  );
});
