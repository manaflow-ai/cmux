// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// A long chat opens on its tail and pages older turns in as the reader scrolls up (cx-2lv1k). A
// session on cmux server can hold thousands of turns: the pane asks acpmux for the newest records
// only, then for the page before its oldest record each time the reader nears the top, until acpmux
// says there is no more. The reader's place holds while pages land above it: a message moves only by
// what the reader scrolled. A long chat left at its end holds its latest line still on every painted
// frame from the first that shows it, while the pane reads its tail and the opener of the tail's turn.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-history-paging.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-history-paging: skipping (run `bunx playwright install chromium`)");
    describe.skip("history paging", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000a11a";
  const START = Date.UTC(2026, 9, 1, 9, 0, 0);
  const TURNS = 500;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [];
  // Every 25th turn only ran a command, so its "Worked for" shows the turn's own time (4s, from the
  // prompt to its result), whatever page it came in on.
  const TOOL_ONLY = 25;
  const tool = (n: number): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: `call-${n}`,
        title: "swift build",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "swift build" },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: `call-${n}`, status: "completed" }),
    ],
  ];
  for (let n = 1; n <= TURNS; n++) {
    if (n % TOOL_ONLY === 0) {
      steps.push(["mux", "user_message", { text: `Question ${n}` }], ["mux", "turn_started", {}], ...tool(n), [
        "mux",
        "turn_result",
        { status: "completed" },
      ]);
      continue;
    }
    steps.push(
      ["mux", "user_message", { text: `Question ${n}` }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", chunk(`Answer ${n}: the build on this branch passes, `)],
      ["in", "agent_message_chunk", chunk("the release compile is green, ")],
      ["in", "agent_message_chunk", chunk("and the checks on the merged head are green.")],
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
  const lastSeq = events.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Long chat",
    harness: "claude",
    // A finished turn here folds under Worked for, whose label this test reads: the Codex family's
    // fold (turns.ts; a Claude chat draws its runs on their own lines instead).
    family: "codex",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq,
  };

  /// acpmux's paging: the newest `limit` records before `beforeSeq`, or the first `limit` after `afterSeq`.
  function page(params: Record<string, any>) {
    const limit = Number(params.limit ?? 2000);
    if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
      const after = events.filter((event) => event.seq > params.afterSeq);
      return { events: after.slice(0, limit), hasMore: after.length > limit, lastSeq };
    }
    const before = events.filter((event) => event.seq < (params.beforeSeq ?? Infinity));
    return { events: before.slice(Math.max(0, before.length - limit)), hasMore: before.length > limit, lastSeq };
  }

  const requests: { method: string; params: Record<string, any>; sent: number }[] = [];
  /// The pane's read of the prompt that opened the turn its tail starts in: user_message records only.
  const isOpenerRead = (request: (typeof requests)[number]) =>
    request.method === "_acpmux/events" &&
    request.params.promptIndex !== true &&
    Array.isArray(request.params.kinds) &&
    request.params.kinds.length === 1 &&
    request.params.kinds[0] === "user_message";
  let inflight = 0;
  /// Replies sent so far: a page that lands while the view looks still restarts the wait.
  let replies = 0;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach": {
        const result = page(params);
        requests.push({ method, params, sent: result.events.length });
        return { session, ...result };
      }
      case "_acpmux/events": {
        const result = page(params);
        requests.push({ method, params, sent: result.events.length });
        return result;
      }
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          // A remote daemon answers a page a little later, as cmux server does over the network.
          inflight++;
          setTimeout(() => {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
            inflight--;
            replies++;
          }, 40);
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

  test("a long chat opens on its tail and pages older turns in as the reader scrolls up, holding its place", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    // The open, and each wheel step, settles: no page in flight and the offset still for 120ms, timed
    // in the page by frame. Polled from here (three reads 40ms apart, after one to start from) it cost
    // four round trips a step: 65s of the 281 steps on the CI runner, where the wheel lands in one
    // frame, and the file ran into its 120s limit when the runner was loaded.
    const settle = async () => {
      for (const started = Date.now(); Date.now() - started < 5_000;) {
        const sent = replies;
        const held = await page.evaluate(
          (left) =>
            new Promise<boolean>((resolve) => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              let last = scroller.scrollTop;
              let since = performance.now();
              const end = since + left;
              window.cmuxAfterPaint((now) => {
                if (scroller.scrollTop !== last) [last, since] = [scroller.scrollTop, now];
                if (now - since >= 120) resolve(true);
                else if (now >= end) resolve(false);
                else return;
                return false;
              });
            }),
          5_000 - (Date.now() - started),
        );
        if (held && inflight === 0 && replies === sent) return;
      }
    };
    await settle();

    // Opening fetched the tail only, and capped its size: acpmux ends a page at maxBytes, the most a
    // remote session's open downloads.
    const attach = requests.find((request) => request.method === "_acpmux/attach")!;
    expect(attach.sent).toBeLessThanOrEqual(400);
    // The only other read at open is the turn opener's (direct.ts fetchTurnOpener): the tail starts
    // mid-turn, so the pane asks for a few prompt records before it to show what that turn was asked.
    const openerReads = requests.filter(isOpenerRead);
    expect(openerReads.length).toBeLessThanOrEqual(1);
    expect(openerReads.every((request) => request.params.limit <= 16)).toBe(true);
    expect(
      requests.filter(
        (request) =>
          request.method === "_acpmux/events" &&
          request.params.limit > 1 &&
          !isOpenerRead(request) &&
          request.params.promptIndex !== true,
      ),
    ).toEqual([]);
    // And the rail's prompt index (direct.ts readPromptIndex): one read, so it lays out every turn.
    expect(requests.filter((request) => request.params.promptIndex === true)).toHaveLength(1);
    expect(attach.params.maxBytes).toBeLessThanOrEqual(128 * 1024);
    expect(await page.getByText("Question 1", { exact: true }).count()).toBe(0);

    // The reader scrolls up with the wheel. Each step, a message in the upper part of the view must
    // move down by at most what the wheel scrolled and stay in view, however many older turns landed
    // above it meanwhile.
    const scroller = page.locator(".acpmux-scroll");
    const box = (await scroller.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const jumps: string[] = [];
    let reachedFirst = false;
    // Every turn passes through the view once, newest first: pages that fold on their own lose,
    // repeat or reorder none.
    const seen: string[] = [];
    const workedLabels = new Set<string>();
    for (let step = 0; step < 800 && !reachedFirst; step++) {
      const before = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = node.getBoundingClientRect();
        const inView = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")]
          .map((bubble) => ({ text: bubble.textContent ?? "", y: bubble.getBoundingClientRect().top - view.top }))
          .filter((bubble) => bubble.y >= 0 && bubble.y < view.height);
        // The mark sits in the upper part of the view, so a 300px step keeps it in view.
        const mark = inView.find((bubble) => bubble.y < view.height - 360);
        const worked = [...document.querySelectorAll<HTMLElement>(".cv-worked__label")].map(
          (label) => label.textContent ?? "",
        );
        return { top: node.scrollTop, mark, shown: inView.map((bubble) => bubble.text), worked };
      });
      for (const text of [...before.shown].reverse()) if (seen.at(-1) !== text && !seen.includes(text)) seen.push(text);
      for (const label of before.worked) workedLabels.add(label);
      await page.mouse.wheel(0, -300);
      await settle();
      const after = await page.evaluate((text) => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = node.getBoundingClientRect();
        const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find(
          (element) => element.textContent === text,
        );
        return {
          top: node.scrollTop,
          y: bubble ? bubble.getBoundingClientRect().top - view.top : undefined,
          first: [...document.querySelectorAll(".cv-user__bubble")].some(
            (element) => element.textContent === "Question 1",
          ),
        };
      }, before.mark?.text ?? "");
      reachedFirst = after.first;
      if (!before.mark) continue;
      if (after.y === undefined) {
        jumps.push(`${before.mark.text}: left the view at scrollTop ${before.top} -> ${after.top}`);
        continue;
      }
      // What the wheel scrolled: at most its own 300px, less only when the view was already near the top.
      const moved = after.y - before.mark.y;
      if (moved < -1 || moved > 301)
        jumps.push(`${before.mark.text}: moved ${moved.toFixed(1)}px at scrollTop ${before.top} -> ${after.top}`);
    }
    await settle();

    const older = requests.filter(
      (request) =>
        request.method === "_acpmux/events" &&
        request.params.beforeSeq &&
        request.params.limit > 1 &&
        request.params.promptIndex !== true &&
        !isOpenerRead(request),
    );
    expect(errors).toEqual([]);
    expect(reachedFirst).toBe(true);
    expect(jumps).toEqual([]);
    const shownFirst = await page.evaluate(() =>
      [...document.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? ""),
    );
    for (const text of [...shownFirst].reverse()) if (!seen.includes(text)) seen.push(text);
    expect(seen).toEqual(Array.from({ length: TURNS }, (_, index) => `Question ${TURNS - index}`));
    // A paged-in turn is timed from its own prompt, not the newest one.
    expect([...workedLabels]).toEqual(["Worked for 4s"]);
    // Older turns came in pages, each before the oldest record the pane held, and stopped at the start.
    expect(older.length).toBeGreaterThan(5);
    expect(older.every((request) => Number(request.params.limit) <= 400)).toBe(true);
    expect(older.every((request) => Number(request.params.maxBytes) <= 256 * 1024)).toBe(true);
    const cursors = older.map((request) => request.params.beforeSeq as number);
    expect(new Set(cursors).size).toBe(cursors.length);
    expect(cursors).toEqual([...cursors].sort((a, b) => b - a));
    expect(older.at(-1)!.sent).toBeGreaterThan(0);
    await page.close();
  });

  test("a long chat opened at its end holds its latest line on every painted frame", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    // From the first painted frame that shows the newest question: where it sits against the view's
    // foot, and how far the view rests from its end.
    await page.addInitScript((newest) => {
      const frames: { t: number; line: number; fromEnd: number }[] = [];
      (window as unknown as { __opened: typeof frames }).__opened = frames;
      window.cmuxAfterPaint((frame) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller || scroller.hasAttribute("data-seeking")) return;
        const bubble = [...scroller.querySelectorAll<HTMLElement>(".cv-user__bubble")].find(
          (each) => each.textContent === newest,
        );
        if (!bubble) return;
        frames.push({
          t: Math.round(frame),
          line: scroller.getBoundingClientRect().bottom - bubble.getBoundingClientRect().top,
          fromEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
        });
      });
    }, `Question ${TURNS}`);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    // fixed-wait: the test watches 3 s of painted frames after open for any jump; the window is the test
    await page.waitForTimeout(3_000);
    const frames = await page.evaluate(
      () => (window as unknown as { __opened: { t: number; line: number; fromEnd: number }[] }).__opened,
    );
    await page.close();
    const moved = frames.flatMap((frame, index) => {
      const before = frames[index - 1];
      return before && Math.abs(frame.line - before.line) > 1
        ? [`${frame.t}ms: ${before.line.toFixed(1)} -> ${frame.line.toFixed(1)}`]
        : [];
    });
    expect({ moved, atEnd: frames.length > 0 && frames.every((frame) => frame.fromEnd <= 4) }).toEqual({
      moved: [],
      atEnd: true,
    });
  });

  // Leo 2026-10-21, after restarting the app on a chat of about 720 turns: "NOW I CAN'T SEE THE
  // PAST HISTORY OF THIS CHAT. WHERE IS OUR PAGINATION?" One older read failed, and while the reply
  // streamed the transcript asked again inside the client's 2 s back-off, got nothing, and never
  // asked again: at the very top a wheel up fires no scroll event. This chat compacted every 100
  // turns, its reply streams while the reader scrolls, it opens on a tail the app kept from long
  // ago that its attach does not continue (the older read already out is dropped when it lands),
  // and its first older read after the attach fails.
  test("a 700-turn chat that compacted pages back to its first message past a dropped and a failed read, while it streams", async () => {
    const LONG = "0190a000-0000-7000-8000-00000000a700";
    const LONG_TURNS = 700;
    const COMPACT_EVERY = 100;
    // Each turn read a build log: pages end at maxBytes long before they reach their record limit.
    const log = "warning: unused variable `x`\n".repeat(110);
    const longSteps: Step[] = [];
    for (let n = 1; n <= LONG_TURNS; n++) {
      longSteps.push(["mux", "user_message", { text: `Question ${n}` }], ["mux", "turn_started", {}]);
      if (n % COMPACT_EVERY === 0)
        longSteps.push(
          ["in", "compaction", update({ sessionUpdate: "compaction", state: "running" })],
          [
            "in",
            "compaction",
            update({ sessionUpdate: "compaction", state: "completed", preTokens: 180_000, postTokens: 12_000 }),
          ],
        );
      longSteps.push(
        [
          "in",
          "tool_call",
          update({
            sessionUpdate: "tool_call",
            toolCallId: `log-${n}`,
            title: "cat build.log",
            kind: "read",
            status: "in_progress",
          }),
        ],
        [
          "in",
          "tool_call_update",
          update({
            sessionUpdate: "tool_call_update",
            toolCallId: `log-${n}`,
            status: "completed",
            content: [{ type: "content", content: { type: "text", text: log } }],
          }),
        ],
        ["in", "agent_message_chunk", chunk(`Answer ${n}.`)],
        // Not a transcript record: a read for `transcript` leaves it out.
        ["in", "usage_update", update({ sessionUpdate: "usage_update", used: n * 100, size: 200_000 })],
      );
      // The last turn is still answering.
      if (n < LONG_TURNS) longSteps.push(["mux", "turn_result", { status: "completed" }]);
    }
    const longEvents = longSteps.map(([dir, kind, msg], index) => ({
      sessionId: LONG,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
    const longSession = {
      sessionId: LONG,
      cwd: "/home/dev/cmux",
      title: "Very long chat",
      harness: "claude",
      // The Codex family's fold, which folds a finished turn's compaction under Worked for (below).
      family: "codex",
      status: "running",
      turnCount: LONG_TURNS,
      updatedAt: START,
      lastSeq: longEvents.length,
    };
    // Another tab read this chat long ago, and the app host kept its tail (tailCache.ts
    // `chat.tail.get`): two whole turns from the middle of its history. The reader is on another
    // chat and switches to this one: the pane draws the tail on the frame the switch lands and asks
    // for the history before it; the attach page then starts far past the tail, so the chat drops
    // it (direct.ts historyEpoch) and that older read, answered after the attach, brings nothing.
    const STALE_TURN = 300;
    const promptSeq = (n: number) =>
      longEvents.find((event) => event.kind === "user_message" && event.msg.text === `Question ${n}`)!.seq;
    const staleFrom = promptSeq(STALE_TURN);
    const staleTo = promptSeq(STALE_TURN + 2) - 1;
    const staleTail = {
      events: longEvents.filter((event) => event.seq >= staleFrom && event.seq <= staleTo),
      historyExhausted: false,
    };
    let staleReads = 0;
    let attachAnsweredAt = 0;
    let staleAnsweredAt = 0;
    /// The chat the reader is on before the switch.
    const OTHER = "0190a000-0000-7000-8000-00000000a701";
    const otherEvents = (
      [
        ["mux", "user_message", { text: "Other question" }],
        ["mux", "turn_started", {}],
        ["in", "agent_message_chunk", chunk("Other answer.")],
        ["mux", "turn_result", { status: "completed" }],
      ] as Step[]
    ).map(([dir, kind, msg], index) => ({
      sessionId: OTHER,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
    const otherSession = {
      ...longSession,
      sessionId: OTHER,
      title: "Other chat",
      status: "ready",
      turnCount: 1,
      lastSeq: otherEvents.length,
    };
    // acpmux hub/paging.rs: `transcript` is every mux record here and every agent update but
    // bookkeeping; a page is the newest `limit` records before `beforeSeq`, ending before its JSON
    // passes `maxBytes`, and always holds at least one record.
    const NOT_TRANSCRIPT = ["usage_update", "available_commands_update", "current_mode_update", "config_option_update"];
    const wanted = (event: (typeof longEvents)[number], kinds: unknown) =>
      !Array.isArray(kinds) ||
      kinds.some((kind) =>
        kind === "all"
          ? true
          : kind === "transcript"
            ? event.dir === "mux" || (event.dir === "in" && !NOT_TRANSCRIPT.includes(event.kind))
            : kind === event.kind,
      );
    function longPage(params: Record<string, any>) {
      const lastSeq = longEvents.length;
      if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
        const after = longEvents.filter((event) => event.seq > params.afterSeq && wanted(event, params.kinds));
        return { events: after, hasMore: false, lastSeq };
      }
      const limit = Number(params.limit ?? 2000);
      const maxBytes = Number(params.maxBytes ?? 1 << 20);
      const pool = longEvents.filter(
        (event) => event.seq < (params.beforeSeq ?? Infinity) && wanted(event, params.kinds),
      );
      const out: typeof longEvents = [];
      let bytes = 0;
      let hasMore = false;
      for (let index = pool.length - 1; index >= 0; index--) {
        const event = pool[index]!;
        bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
        if (out.length === limit || (out.length > 0 && bytes > maxBytes)) {
          hasMore = true;
          break;
        }
        out.push(event);
      }
      return { events: out.reverse(), hasMore, lastSeq };
    }
    const longRequests: { method: string; params: Record<string, any>; failed?: boolean; dropped?: boolean }[] = [];
    let failedOnce = false;
    let longInflight = 0;
    let longReplies = 0;
    const sockets = new Set<{ send(data: string): void }>();
    const longDaemon = Bun.serve({
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const params = message.params ?? {};
          let reply: Record<string, unknown>;
          // A remote daemon answers a little later; the attach of a long chat later still, so the
          // kept tail's older read goes out while it is in flight, and is answered after it.
          let delay = 40;
          let answered = () => {};
          if (message.method === "initialize")
            reply = {
              result: { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } },
            };
          else if (message.method === "_acpmux/watch")
            reply = { result: { sessions: [{ ...longSession, lastSeq: longEvents.length }, otherSession] } };
          else if (params.sessionId === OTHER && message.method === "_acpmux/attach")
            reply = {
              result: { session: otherSession, events: otherEvents, hasMore: false, lastSeq: otherEvents.length },
            };
          else if (params.sessionId === OTHER && message.method === "_acpmux/events")
            reply = { result: { events: [], hasMore: false, lastSeq: otherEvents.length } };
          else if (message.method === "_acpmux/attach") {
            longRequests.push({ method: message.method, params });
            reply = { result: { session: { ...longSession, lastSeq: longEvents.length }, ...longPage(params) } };
            delay = 1_500;
            answered = () => (attachAnsweredAt ||= performance.now());
          } else if (message.method === "_acpmux/events") {
            const older = Array.isArray(params.kinds) && params.kinds.includes("transcript");
            if (older && attachAnsweredAt === 0 && Number(params.beforeSeq) === staleFrom) {
              // The read off the kept tail: answered once the attach has replaced that tail.
              staleReads++;
              longRequests.push({ method: message.method, params, dropped: true });
              reply = { result: longPage(params) };
              delay = 2_500;
              answered = () => (staleAnsweredAt = performance.now());
            } else if (older && !failedOnce) {
              // The first older transcript read after the attach fails, as one over a dropped connection does.
              failedOnce = true;
              longRequests.push({ method: message.method, params, failed: true });
              reply = { error: { code: -32000, message: "connection reset by peer" } };
            } else {
              longRequests.push({ method: message.method, params });
              reply = { result: longPage(params) };
            }
          } else reply = { result: null };
          longInflight++;
          setTimeout(() => {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, ...reply }));
            answered();
            longInflight--;
            longReplies++;
          }, delay);
        },
      },
    });
    // The reply goes on streaming while the reader scrolls: the pane renders on every chunk.
    let pushed = 0;
    const live = setInterval(() => {
      if (sockets.size === 0 || attachAnsweredAt === 0) return;
      const event = {
        sessionId: LONG,
        seq: longEvents.length + 1,
        at: START + longEvents.length * 1000,
        dir: "in",
        kind: "agent_message_chunk",
        msg: chunk(` more ${pushed}`),
      };
      longEvents.push(event);
      pushed++;
      for (const socket of sockets)
        socket.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    }, 100);
    // A tall view, so each wheel step can be long and still show every prompt as it passes.
    const page = await browser!.newPage({ viewport: { width: 900, height: 1400 } });
    try {
      await installPaintedFrames(page);
      const errors: string[] = [];
      page.on("pageerror", (error) => errors.push(error.message));
      // The app host's side of tailCache.ts: it answers with the old tail, and takes what the page
      // hands it. The pane installs its own actions once it runs; these stay among them.
      await page.addInitScript(
        ([sessionId, tail]) => {
          const host = {
            "chat.tail.get": async (params: { sessionId?: unknown }) => (params.sessionId === sessionId ? tail : null),
            "chat.tail": async () => null,
          };
          let actions: Record<string, unknown> = { ...host };
          Object.defineProperty(window, "cmuxAcpmuxActions", {
            configurable: true,
            get: () => actions,
            set: (next: Record<string, unknown>) => void (actions = { ...next, ...host }),
          });
        },
        [LONG, staleTail] as const,
      );
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${longDaemon.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${OTHER}`);
      await page.getByText("Other question", { exact: true }).waitFor({ timeout: 60_000 });
      // The reader switches to the long chat, as a pick in the chat list does.
      await page.evaluate(
        (sessionId) =>
          (window as unknown as { cmuxAcpmuxActions: Record<string, (params: unknown) => Promise<unknown>> })
            .cmuxAcpmuxActions["chat.select"]!({ sessionId }),
        LONG,
      );
      await page.getByText(`Question ${LONG_TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
      // A wheel step settles: no read in flight and the offset still for 60ms, timed in the page.
      const settle = async () => {
        for (const started = Date.now(); Date.now() - started < 5_000;) {
          const sent = longReplies;
          const held = await page.evaluate(
            (left) =>
              new Promise<boolean>((resolve) => {
                const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
                let last = scroller.scrollTop;
                let since = performance.now();
                const end = since + left;
                window.cmuxAfterPaint((now) => {
                  if (scroller.scrollTop !== last) [last, since] = [scroller.scrollTop, now];
                  if (now - since >= 60) resolve(true);
                  else if (now >= end) resolve(false);
                  else return;
                  return false;
                });
              }),
            5_000 - (Date.now() - started),
          );
          if (held && longInflight === 0 && longReplies === sent) return;
        }
      };
      await settle();
      // The chat opened on its latest screenful, from one capped page.
      const attach = longRequests.find((request) => request.method === "_acpmux/attach");
      expect(Number(attach?.params.maxBytes)).toBeLessThanOrEqual(128 * 1024);
      expect(await page.getByText("Question 1", { exact: true }).count()).toBe(0);

      const scroller = page.locator(".acpmux-scroll");
      const box = (await scroller.boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      // Each prompt and each compaction note, as it passes through the view, newest first.
      const seen: string[] = [];
      let reachedFirst = false;
      let stuck = 0;
      const look = () =>
        page.evaluate(() => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const view = node.getBoundingClientRect();
          const items = [...node.querySelectorAll<HTMLElement>(".cv-user__bubble, .cv-compaction")]
            .map((element) => ({
              id: element.classList.contains("cv-compaction")
                ? `compaction:${element.closest<HTMLElement>(".acpmux-row")?.dataset.rowId ?? "?"}`
                : (element.textContent ?? ""),
              y: element.getBoundingClientRect().top - view.top,
            }))
            .filter((item) => item.y >= 0 && item.y < view.height)
            .sort((a, b) => a.y - b.y)
            .map((item) => item.id);
          return { top: node.scrollTop, items };
        });
      let steps = 0;
      for (; steps < 1_500 && !reachedFirst && stuck < 40; steps++) {
        const before = await look();
        for (const id of [...before.items].reverse()) if (!seen.includes(id)) seen.push(id);
        await page.mouse.wheel(0, -900);
        await settle();
        const after = await look();
        reachedFirst = after.items.includes("Question 1");
        // At the top with nothing new: a transcript that stopped asking stays here for good.
        stuck = after.top === 0 && before.top === 0 && after.items.join() === before.items.join() ? stuck + 1 : 0;
      }
      await settle();
      for (const id of [...(await look()).items].reverse()) if (!seen.includes(id)) seen.push(id);

      console.log(
        `700-turn chat: ${steps} wheel steps; kept-tail reads ${staleReads}, answered ${Math.round(staleAnsweredAt - attachAnsweredAt)} ms after the attach`,
      );
      expect(errors).toEqual([]);
      expect(failedOnce).toBe(true);
      // The kept tail was drawn and read from, and that read landed after the attach dropped it.
      expect(staleReads).toBeGreaterThan(0);
      expect(attachAnsweredAt).toBeGreaterThan(0);
      expect(staleAnsweredAt).toBeGreaterThan(attachAnsweredAt);
      expect(pushed).toBeGreaterThan(10);
      expect({ reachedFirst, oldestSeen: seen.at(-1) }).toEqual({ reachedFirst: true, oldestSeen: "Question 1" });
      // Every prompt once and in order. A finished turn folds its compaction with its work under
      // "Worked for" (turns.ts, Leo 2026-10-21: fold only the work); the turn still streaming shows
      // its compaction where it happened, under its prompt.
      expect(seen.map((id) => (id.startsWith("compaction:") ? "compaction" : id))).toEqual(
        Array.from({ length: LONG_TURNS }, (_, index) => LONG_TURNS - index).flatMap((n) =>
          n === LONG_TURNS ? ["compaction", `Question ${n}`] : [`Question ${n}`],
        ),
      );
      expect(new Set(seen.filter((id) => id.startsWith("compaction:"))).size).toBe(1);
      // The pane read its history in bounded pages, each before the oldest record it held.
      const older = longRequests.filter(
        (request) =>
          request.method === "_acpmux/events" &&
          !request.failed &&
          !request.dropped &&
          request.params.kinds?.includes("transcript"),
      );
      expect(older.length).toBeGreaterThan(3);
      expect(older.every((request) => Number(request.params.maxBytes) <= 256 * 1024)).toBe(true);
      const cursors = older.map((request) => request.params.beforeSeq as number);
      expect(cursors).toEqual([...cursors].sort((a, b) => b - a));
    } finally {
      clearInterval(live);
      await page.close();
      await longDaemon.stop(true);
    }
  });
});
