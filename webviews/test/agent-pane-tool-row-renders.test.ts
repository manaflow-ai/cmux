// cmux-web-test-timeout: 300
// l10n-allow-file: the stand-in daemon's fixture turns, not shipped UI.
// A tool call that has settled draws nothing again while the rest of the chat streams: no commit
// and no remount of its row when another call starts, runs, prints or ends, or the reply streams.
// Each such redraw replays the row's shimmer, fold or fade and reads as a flicker (Leo,
// 2026-11-14: "im also seeing more flickers/rerenders of tool calls recently").
//
// The real pane over a stand-in acpmux daemon whose socket pushes each step live (as
// agent-pane-one-row-per-call.test.ts). The chat holds a finished turn whose "Worked for" is open,
// so its calls are drawn, and a running turn under the default live-turn-work arm (`runs`), whose
// finished runs stay in sight. Every call row counts its commits and mounts
// (conversation/toolRowCount.ts) through `cmuxAcpmuxDebug.renders()`.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-tool-row-renders.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-tool-row-renders: skipping (run `bunx playwright install chromium`)");
    describe.skip("tool row renders", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LIVE = "0190a000-0000-7000-8000-0000000000d4";
  const START = Date.now() - 10 * 60_000;
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const say = (messageId: string, text: string): Step => [
    "in",
    "agent_message_chunk",
    update({ sessionUpdate: "agent_message_chunk", messageId, content: { type: "text", text } }),
  ];
  const think = (text: string): Step => [
    "in",
    "agent_thought_chunk",
    update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } }),
  ];
  const start = (id: string, title: string, kind: string, rawInput: Record<string, unknown>, more = {}): Step => [
    "in",
    "tool_call",
    update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "pending", rawInput, ...more }),
  ];
  const progress = (id: string, more: Record<string, unknown> = {}): Step => [
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "in_progress", ...more }),
  ];
  const output = (id: string, text: string): Step => [
    "in",
    "tool_call_update",
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "in_progress",
      content: [{ type: "content", content: { type: "text", text } }],
    }),
  ];
  const done = (id: string): Step => [
    "in",
    "tool_call_update",
    update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed" }),
  ];
  const read = (id: string, file: string): Step[] => [
    start(
      id,
      `Read ${file}`,
      "read",
      { file_path: `/home/dev/app/${file}` },
      { locations: [{ path: `/home/dev/app/${file}` }] },
    ),
    progress(id),
    done(id),
  ];
  const bash = (id: string, command: string): Step[] => [
    start(id, command, "execute", { command }),
    progress(id),
    output(id, "ok 1\n"),
    done(id),
  ];
  const T1 = "0190a000-0000-7000-8000-00000000d401";
  const T2 = "0190a000-0000-7000-8000-00000000d402";
  /// A finished turn with five calls and a reply, then a running turn with its first two calls.
  const history: Step[] = [
    ["mux", "user_message", { text: "Find why the build is slow", promptId: "p-1", turnId: T1 }],
    ["mux", "turn_started", { turnId: T1, promptId: "p-1" }],
    ...read("h-read-1", "build.ts"),
    ...read("h-read-2", "vite.config.ts"),
    ...bash("h-bash-1", "bun run build --profile"),
    ...read("h-read-3", "tsconfig.json"),
    ...bash("h-bash-2", "git log --oneline -5"),
    say("m-1", "The build spends most of its time type checking the generated files."),
    ["mux", "turn_result", { status: "completed", turnId: T1 }],
    ["mux", "user_message", { text: "Fix it and run the tests", promptId: "p-2", turnId: T2 }],
    ["mux", "turn_started", { turnId: T2, promptId: "p-2" }],
    ...read("l-read-1", "tsconfig.json"),
    ...bash("l-bash-1", "bun run typecheck"),
    say("m-2", "Excluding the generated folder."),
  ];
  /// What streams while the test counts: more calls start, print and end, and the reply streams.
  const stream: Step[] = [
    think("Checking which tests cover the build. "),
    think("Checking which tests cover the build. The config test does."),
    ...read("l-read-2", "package.json"),
    ...bash("l-bash-2", "bun test src/build"),
    say("m-3", "The tests pass. "),
    output("l-bash-2", "ok 1\nok 2\n"),
    ...read("l-read-3", "README.md"),
    say("m-3", "The tests pass. Running the build once more"),
    ...bash("l-bash-3", "bun run build"),
    say("m-3", "The tests pass. Running the build once more to time it."),
  ];
  const SETTLED_HISTORY = ["h-read-1", "h-read-2", "h-bash-1", "h-read-3", "h-bash-2"];
  const SETTLED_LIVE = ["l-read-1", "l-bash-1"];

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
    cwd: "/home/dev/app",
    title: "Slow build",
    harness: "claude",
    family: "claude",
    status: "running",
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

  const frames = (page: Page, count = 2) =>
    page.evaluate(
      (n) =>
        new Promise<void>((resolve) => {
          const step = (left: number) => (left <= 0 ? resolve() : requestAnimationFrame(() => step(left - 1)));
          step(n);
        }),
      count,
    );
  /// Waits until the page has drawn 10 frames in a row with no element added or removed and no
  /// animation that ends still playing (a fold, a fade, a row's entrance), so what is counted next is the stream's alone.
  const quiet = (page: Page) =>
    page.waitForFunction(
      () =>
        new Promise<boolean>((resolve) => {
          let changed = false;
          const observer = new MutationObserver(() => (changed = true));
          observer.observe(document.body, { childList: true, subtree: true });
          const step = (left: number) => {
            // A live line's shimmer loops for as long as the turn runs: only an animation that ends counts.
            const playing = document
              .getAnimations()
              .some((each) => each.playState === "running" && each.effect?.getComputedTiming().iterations !== Infinity);
            if (changed || playing) {
              observer.disconnect();
              return resolve(false);
            }
            if (left === 0) {
              observer.disconnect();
              return resolve(true);
            }
            requestAnimationFrame(() => step(left - 1));
          };
          requestAnimationFrame(() => step(10));
        }),
      null,
      { timeout: 15_000, polling: 50 },
    );
  const renders = (page: Page) =>
    page.evaluate(() => (window as any).cmuxAcpmuxDebug.renders() as Record<string, number>);
  /// Starts counting what a stream does to the transcript's drawn elements besides the live ones:
  /// an element that leaves the page (`removed`; one back with the same words is `replaced`) and an
  /// animation or transition that starts on one (`animated`). Either repaints a settled row.
  const watchReplaced = (page: Page) =>
    page.evaluate(() => {
      const SEL = "[data-row-id], .cv-tool, .cv-worked, .cv-step";
      const LIVE = '[data-row-id="thinking-live"], .cv-worked.is-below';
      const name = (node: Element) =>
        `${node.closest("[data-row-id]")?.getAttribute("data-row-id") ?? "?"} ${node.tagName.toLowerCase()}.${String(node.className).trim().split(/\s+/).join(".")}`;
      const key = (node: Element) => `${name(node)}|${(node.textContent ?? "").trim().slice(0, 60)}`;
      const before = new Map<Element, string>();
      for (const node of document.querySelectorAll(SEL)) if (!node.closest(LIVE)) before.set(node, key(node));
      const removed = new Map<string, number>();
      const animated = new Map<string, number>();
      const observer = new MutationObserver((records) => {
        for (const record of records)
          for (const node of record.removedNodes) {
            if (!(node instanceof Element)) continue;
            for (const each of [node, ...node.querySelectorAll(SEL)]) {
              const was = before.get(each);
              if (was) removed.set(was, (removed.get(was) ?? 0) + 1);
            }
          }
      });
      observer.observe(document.body, { childList: true, subtree: true });
      const started = (event: Event) => {
        const target = event.target as Element | null;
        if (!target?.closest || !target.closest("[data-row-id]") || target.closest(LIVE)) return;
        // Only on what was drawn before the stream: a new row's own entrance is no flicker.
        if (![...before.keys()].some((node) => node === target || node.contains(target))) return;
        const what = `${(event as AnimationEvent).animationName ?? (event as TransitionEvent).propertyName} on ${name(target)}`;
        animated.set(what, (animated.get(what) ?? 0) + 1);
      };
      document.addEventListener("animationstart", started, true);
      document.addEventListener("transitionstart", started, true);
      (window as any).__replaced = () => {
        observer.disconnect();
        document.removeEventListener("animationstart", started, true);
        document.removeEventListener("transitionstart", started, true);
        const now = new Set([...document.querySelectorAll(SEL)].map(key));
        const out = (map: Map<string, number>) => [...map].map(([was, n]) => `${n}x ${was}`);
        return {
          replaced: out(new Map([...removed].filter(([was]) => now.has(was)))),
          removed: out(removed),
          animated: out(animated),
        };
      };
    });
  const replaced = (page: Page) =>
    page.evaluate(() => (window as any).__replaced() as { replaced: string[]; removed: string[]; animated: string[] });
  /// Opens the chat, opens what `openAll` says, streams `stream` and reads what drew again.
  async function measure(openAll: boolean) {
    seq = events.length;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 1400 } });
    for (let attempt = 1; ; attempt++) {
      try {
        await page.goto(url());
        await page.waitForFunction(() => "cmuxAcpmuxDebug" in window, null, { timeout: 30_000 });
        await page.locator(".cv-worked.is-toggle").first().waitFor({ timeout: 25_000 });
        break;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
    // Measuring starts here, so the calls the opens below draw count their mounts.
    await renders(page);
    // Open the finished turn's "Worked for", then every run line in sight, so each settled call draws.
    if (openAll) await page.locator(".cv-worked.is-toggle").first().click();
    await frames(page, 30);
    for (let pass = 0; openAll && pass < 3; pass++) {
      const closed = page.locator('.cv-tool.is-run[aria-expanded="false"]');
      const count = await closed.count();
      if (count === 0) break;
      for (let index = 0; index < count; index++) await closed.nth(0).click();
      await frames(page, 30);
    }
    await quiet(page);
    const opened = await renders(page);
    const drawn = new Set(
      Object.keys(opened)
        .filter((key) => key.startsWith("tool-mount:"))
        .map((key) => key.slice("tool-mount:".length)),
    );
    await quiet(page);
    // Nothing draws at rest.
    const rest = Object.entries(await renders(page)).filter(([key]) => key.startsWith("tool"));
    await watchReplaced(page);
    for (const step of stream) {
      push(step);
      await frames(page, 3);
    }
    await quiet(page);
    await frames(page, 4);
    const after = await renders(page);
    const gone = await replaced(page);
    const settled = [...SETTLED_HISTORY, ...SETTLED_LIVE];
    const report = Object.fromEntries(
      settled.map((id) => [
        id,
        { drawn: drawn.has(id), commits: after[`tool:${id}`] ?? 0, mounts: after[`tool-mount:${id}`] ?? 0 },
      ]),
    );
    const rows = Object.fromEntries(Object.entries(after).filter(([key]) => /^(row|content|remount|mount):/.test(key)));
    console.log(
      `TOOL-ROW-RENDERS ${JSON.stringify({ openAll, steps: stream.length, rest, settled: report, replaced: gone, rows })}`,
    );
    await page.close();
    return { rest, drawn, report, settled, gone };
  }

  test("a settled tool call's row neither draws again nor remounts while the chat streams", async () => {
    const { rest, drawn, report, settled, gone } = await measure(true);
    expect(rest).toEqual([]);
    // The finished turn's calls are drawn, and so is at least one settled call of the running turn.
    expect(SETTLED_HISTORY.filter((id) => !drawn.has(id))).toEqual([]);
    expect(SETTLED_LIVE.some((id) => drawn.has(id))).toBe(true);
    const redrawn = settled.filter((id) => report[id]!.commits > 0 || report[id]!.mounts > 0);
    expect(redrawn.map((id) => [id, report[id]])).toEqual([]);
    expect(gone.replaced).toEqual([]);
    expect(gone.animated).toEqual([]);
  });

  test("with the chat as it opens, no drawn row, call or run line is replaced while the chat streams", async () => {
    const { gone } = await measure(false);
    expect(gone.replaced).toEqual([]);
    expect(gone.animated).toEqual([]);
  });
});
