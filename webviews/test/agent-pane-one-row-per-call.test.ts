// l10n-allow-file: test fixture prompts, paths and tool titles, not shipped UI.
// One tool call is one row in the real agent pane from pending to done (Leo, 2026-11-07, on a
// pending "Writing a file" row over a "Write 12s" line for the same call: "sometimes you can just
// combine the, like, whatever command or action you're doing sooner than you do"). A Write arrives
// as acpmux sends Claude Code's (claude_stdio/early_calls.rs): named as its block starts, pending
// with no input; whole once its input came, in_progress; then completed. While it runs the pane
// draws the call once, on the turn's live line, and the line's top never moves. Once it is done
// the retained `line` look of live-turn-work draws no row for it while the turn runs (turns.ts
// `codexRuns`, 8a37e5fcf650): the line reads Thinking, then the next call, on the same pixel.
//
// Real Chromium from Playwright, the pane's dev entry over a stand-in acpmux daemon whose socket
// pushes each step live; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { CLOCK_ON_LINE, pinArms } from "./support/pinArms";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-one-row-per-call.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-one-row-per-call: skipping (run `bunx playwright install chromium`)");
    describe.skip("one row per call", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LIVE = "0190a000-0000-7000-8000-0000000000c7";
  const START = Date.now() - 60_000;
  const FILE = "/home/dev/fleetviz/gen.py";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const history: Step[] = [
    ["mux", "user_message", { text: "Make a generator for the fleet status page" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "On it." } }),
    ],
  ];
  // The Write's three steps, each its own live push.
  const steps: Record<string, Step> = {
    pending: [
      "in",
      "tool_call",
      update({ sessionUpdate: "tool_call", toolCallId: "toolu_w", title: "Write", kind: "edit", status: "pending" }),
    ],
    running: [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "toolu_w",
        title: "Write gen.py",
        kind: "edit",
        status: "in_progress",
        rawInput: { file_path: FILE, content: "print('ok')\n" },
        locations: [{ path: FILE }],
      }),
    ],
    done: [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "toolu_w", status: "completed" }),
    ],
    // The next call: the finished Write folds into its run, as any finished step does.
    next: [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "toolu_r",
        title: "Read gen.py",
        kind: "read",
        status: "in_progress",
        locations: [{ path: FILE }],
      }),
    ],
  };
  const event = ([dir, kind, msg]: Step, seq: number) => ({
    sessionId: LIVE,
    seq,
    at: START + seq * 1000,
    dir,
    kind,
    msg,
  });
  const events = history.map((step, index) => event(step, index + 1));
  const session = {
    sessionId: LIVE,
    cwd: "/home/dev/fleetviz",
    title: "Fleet status",
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
  const sockets = new Set<{ send(data: string): void }>();
  let seq = events.length;
  const push = (step: Step) => {
    seq += 1;
    const data = JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event(step, seq) });
    for (const socket of sockets) socket.send(data);
  };
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${LIVE}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// What the pane draws for the Write: the rows naming it (a tool row or the live line) and the
  /// live line's top.
  const drawn = (page: Page) =>
    page.evaluate(() => {
      const line = document.querySelector(".cv-worked.is-below");
      // Each transcript row (VirtualTranscript.tsx `data-row-id`) that names the call.
      // Some labels draw their words from `data-text` attributes (ToolVerb.tsx, the shimmer).
      const words = (node: Element) =>
        [
          node.textContent ?? "",
          ...[...node.querySelectorAll("[data-text]")].map((each) => each.getAttribute("data-text")),
        ].join(" ");
      const rows = [...document.querySelectorAll("[data-row-id]")].filter((node) =>
        /\b(Write|Writing|Wrote)\b/.test(words(node)),
      );
      return {
        ids: rows.map((node) => node.getAttribute("data-row-id")),
        rows: rows.length,
        line: line?.querySelector(".cv-thinking")?.textContent ?? "",
        top: line ? Math.round(line.getBoundingClientRect().top) : undefined,
      };
    });

  test("a Write is one row from pending to done, and that row's top does not move", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await pinArms(page, { ...CLOCK_ON_LINE, "live-turn-work": "line" });
    for (let attempt = 1; ; attempt++) {
      try {
        await page.goto(url());
        await page.locator(".cv-worked.is-below").waitFor({ timeout: 25_000 });
        break;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
    const seen: Awaited<ReturnType<typeof drawn>>[] = [];
    for (const name of ["pending", "running", "done", "next"] as const) {
      const before = (await drawn(page)).line;
      push(steps[name]!);
      // The step has drawn once the live line's words change.
      await page.waitForFunction(
        (text) => document.querySelector(".cv-worked.is-below .cv-thinking")?.textContent !== text,
        before,
        { timeout: 10_000 },
      );
      // Two frames for any row that would come or go with the step.
      await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
      seen.push(await drawn(page));
    }
    console.log("ONE_ROW_STEPS", JSON.stringify(seen));
    // Past the call: the next one on the line, and still no row for the finished Write.
    const next = seen.pop()!;
    expect(next.line).toStartWith("Read");
    // Was [1, 1, 1] under the `runs` look, where the finished Write drew as a row of its run. Under
    // the retained `line` look a finished call of a running turn draws no row.
    expect(seen.map((step) => step.rows)).toEqual([1, 1, 0]);
    // Pending and running: the same row, one id, its top still. Done: the line lets the Write go
    // the moment it completes and reads Thinking (Leo, 2026-11-07: "Why don't we just immediately
    // switch to the thinking?"), never a run's row and the line at once.
    const [pending, running, done] = seen;
    expect(running!.ids).toEqual(pending!.ids);
    expect(running!.top).toBe(pending!.top);
    expect(done!.ids).not.toEqual(pending!.ids);
    expect(done!.ids).toEqual(next.ids);
    // Nothing came in above the line when the Write finished or the next call started.
    expect(done!.top).toBe(pending!.top);
    expect(next.top).toBe(pending!.top);
    // The line says what the call's own row would while it runs, then Thinking.
    expect(seen.map((step) => step.line.replace(/\s*\d.*$/, "").replace(/ · .*$/, ""))).toEqual([
      "Writing a file",
      "Writing gen.py",
      "Thinking",
    ]);
    await page.close();
  });
});
