// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, not shipped UI.
// An adopted Claude Code chat whose log holds only its transcript's newest page (acpmux
// adopt_replay_page.rs) pages the older turns in from the transcript as the reader scrolls up
// (`_acpmux/native_history`, direct.ts fetchNativeOlder), and the reader's place holds while each
// page lands above it, as for the log's own older pages (agent-pane-history-paging.test.ts).
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-native-history-scroll.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-native-history-scroll: skipping (run `bunx playwright install chromium`)");
    describe.skip("native history paging", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000b11a";
  const START = Date.UTC(2026, 9, 29, 9, 0, 0);
  /// Turns 1-160 are in the transcript only, in pages of 40; 161-200 were seeded into the log.
  const TURNS = 200;
  const SEEDED = 40;
  const PAGE_TURNS = 40;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// A turn as acpmux logs an adopted one (hub/native_history.rs turn_records).
  const turn = (n: number): Step[] => [
    ["mux", "turn_started", { prompt: `Question ${n}`, turnId: `t-${n}` }],
    ["mux", "user_message", { text: `Question ${n}`, client: "adopt", turnId: `t-${n}` }],
    [
      "in",
      "agent_message_chunk",
      update({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: `Answer ${n}: the build on this branch passes and its checks are green.` },
      }),
    ],
    ["mux", "turn_end", { stopReason: "end_turn", turnId: `t-${n}` }],
    ["mux", "turn_result", { status: "completed", stopReason: "end_turn", turnId: `t-${n}` }],
  ];
  /// The byte cursor where turn `n` starts in the transcript (any increasing offsets do).
  const offset = (n: number) => (n - 1) * 10_000;
  /// acpmux's seq for the `k`th record of the native page that ends at `before` (`native_seq`).
  const nativeSeq = (before: number, k: number) => before * 2 ** 18 + k - 2 ** 52;
  const firstSeeded = TURNS - SEEDED + 1;
  const events = (
    [
      ["mux", "created", { harness: "claude" }],
      ["mux", "adopted", { agentSessionId: "s1" }],
      ["mux", "native_history", { family: "claude", before: offset(firstSeeded), turns: SEEDED }],
      ...Array.from({ length: SEEDED }, (_, i) => turn(firstSeeded + i)).flat(),
    ] as Step[]
  ).map(([dir, kind, msg], index) => ({ sessionId: CHAT, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
  const lastSeq = events.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Adopted chat",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: SEEDED,
    updatedAt: START,
    lastSeq,
  };
  /// The native page that ends at `before`: the PAGE_TURNS turns before it.
  function nativePage(before: number) {
    const last = before / 10_000; // the turn before the cursor's
    const first = Math.max(1, last - PAGE_TURNS + 1);
    const steps = Array.from({ length: last - first + 1 }, (_, i) => turn(first + i)).flat();
    return {
      events: steps.map(([dir, kind, msg], k) => ({
        sessionId: CHAT,
        seq: nativeSeq(before, k),
        at: START - (before - k) * 10,
        dir,
        kind,
        msg,
      })),
      before: first > 1 ? offset(first) : 0,
      turns: last - first + 1,
    };
  }

  const nativeReads: number[] = [];
  let inflight = 0;
  let replies = 0;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: ["_acpmux/native_history"], operations: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, events, hasMore: false, lastSeq };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq };
      case "_acpmux/native_history":
        nativeReads.push(params.before);
        return nativePage(params.before);
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
          // A transcript page is read off the disk: it answers a little later.
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

  test("an adopted chat pages its transcript's older turns in as the reader scrolls up, holding its place", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    // No page in flight and the offset still for 120ms, timed in the page by frame.
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
    expect(await page.getByText("Question 1", { exact: true }).count()).toBe(0);

    const scroller = page.locator(".acpmux-scroll");
    const box = (await scroller.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    const jumps: string[] = [];
    const seen: string[] = [];
    let reachedFirst = false;
    for (let step = 0; step < 600 && !reachedFirst; step++) {
      const before = await page.evaluate(() => {
        const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = node.getBoundingClientRect();
        const inView = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")]
          .map((bubble) => ({ text: bubble.textContent ?? "", y: bubble.getBoundingClientRect().top - view.top }))
          .filter((bubble) => bubble.y >= 0 && bubble.y < view.height);
        const mark = inView.find((bubble) => bubble.y < view.height - 360);
        return { top: node.scrollTop, mark, shown: inView.map((bubble) => bubble.text) };
      });
      for (const text of [...before.shown].reverse()) if (seen.at(-1) !== text && !seen.includes(text)) seen.push(text);
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
      const moved = after.y - before.mark.y;
      if (moved < -1 || moved > 301)
        jumps.push(`${before.mark.text}: moved ${moved.toFixed(1)}px at scrollTop ${before.top} -> ${after.top}`);
    }
    await settle();
    const shownFirst = await page.evaluate(() =>
      [...document.querySelectorAll(".cv-user__bubble")].map((bubble) => bubble.textContent ?? ""),
    );
    for (const text of [...shownFirst].reverse()) if (!seen.includes(text)) seen.push(text);
    expect(errors).toEqual([]);
    expect(reachedFirst).toBe(true);
    expect(jumps).toEqual([]);
    // Every turn once, newest first, from the seeded page back to the transcript's first.
    expect(seen).toEqual(Array.from({ length: TURNS }, (_, index) => `Question ${TURNS - index}`));
    // Each page once, each before the one before it, back to the transcript's start.
    expect(nativeReads).toEqual([4, 3, 2, 1].map((p) => offset(p * PAGE_TURNS + 1)));
    await page.close();
  });
});
