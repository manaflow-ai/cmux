// l10n-allow-file: test fixture prompts, not shipped UI.
// A long chat opens on its tail and pages older turns in as the reader scrolls up (cx-2lv1k). A
// session on cmux server can hold thousands of turns: the pane asks acpmux for the newest records
// only, then for the page before its oldest record each time the reader nears the top, until acpmux
// says there is no more. The reader's place holds while pages land above it: a message moves only by
// what the reader scrolled.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
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
    family: "claude",
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
    Array.isArray(request.params.kinds) &&
    request.params.kinds.length === 1 &&
    request.params.kinds[0] === "user_message";
  let inflight = 0;
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
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    await page.waitForTimeout(500);

    // Opening caps the tail page, then completes its boundary turn so a reply or render fence is
    // never truncated. This fixture's boundary is within one older page; nothing else is prefetched.
    const attach = requests.find((request) => request.method === "_acpmux/attach")!;
    expect(attach.sent).toBeLessThanOrEqual(400);
    expect(
      requests.filter(
        (request) => request.method === "_acpmux/events" && request.params.limit > 1 && !isOpenerRead(request),
      ),
    ).toEqual([
      {
        method: "_acpmux/events",
        params: {
          sessionId: CHAT,
          beforeSeq: lastSeq - attach.sent + 1,
          limit: 400,
          maxBytes: 256 * 1024,
          kinds: ["transcript"],
        },
        sent: 400,
      },
    ]);
    expect(attach.params.maxBytes).toBeLessThanOrEqual(128 * 1024);
    expect(await page.getByText("Question 1", { exact: true }).count()).toBe(0);

    // Each wheel step settles: no page in flight and the offset still for three reads.
    const settle = async () => {
      let last = -1;
      for (let still = 0, waited = 0; still < 3 && waited < 5_000; waited += 40) {
        await page.waitForTimeout(40);
        const top = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
        still = inflight === 0 && top === last ? still + 1 : 0;
        last = top;
      }
    };
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
    await page.waitForTimeout(500);

    const older = requests.filter(
      (request) =>
        request.method === "_acpmux/events" &&
        request.params.beforeSeq &&
        request.params.limit > 1 &&
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
});
