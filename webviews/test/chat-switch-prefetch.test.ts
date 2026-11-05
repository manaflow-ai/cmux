// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
// cmux-web-test-timeout: 300
//
// The user, 2026-10-21: "switching between different chiefs and messages/conversations needs
// instant loading of messages." A chat the page read before already draws on the frame the switch
// lands (tailCache.ts, chat-open-perf.test.ts). A chat it never read waited on acpmux's attach
// round trip, behind the switch's hold. This holds the pane to the rest of the ask:
//
//   - the chats at the top of the list (the ones a person switches to) are read ahead while the
//     pane is idle, so the first switch to one draws it from memory, before its attach answers;
//   - a chat the host or the list asks for ahead of a press (`chat.prefetch`, a hover) does too;
//   - what the chat did since it was read ahead still lands, from the attach, under the drawn rows;
//   - reading ahead never evicts a chat the reader opened from the page's kept tails.
//
// The daemon here answers an attach only after ATTACH_MS (far past the switch's 400 ms hold), so a
// chat that draws before SWITCH_DRAWN_MS can only have drawn from memory. The log prints the
// select-to-painted-frame times (p50/p95) for the report.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-switch-prefetch.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("chat-switch-prefetch: skipping (run `bunx playwright install chromium`)");
    describe.skip("chat switch prefetch", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  const CHAT_COUNT = 60;
  /// A busy daemon's attach: longer than the switch's hold, so an open that waits on it shows.
  const ATTACH_MS = 1_500;
  /// Any other call (the read-ahead's event page among them).
  const CALL_MS = 20;
  /// A switch drawn from memory lands on its first frames; one that waited on the attach cannot
  /// draw before ATTACH_MS. Generous for the dev bundle's render frame on a loaded runner.
  const SWITCH_DRAWN_MS = 700;
  /// The recent chats a person switches between; each is in the read-ahead's reach.
  const RECENT = 8;

  const chat = (index: number) => {
    const sessionId = `0190b000-0000-7000-8000-${String(index).padStart(12, "0")}`;
    const marker = `Chat ${index} tail reached.`;
    const listed = {
      sessionId,
      cwd: `/home/dev/project-${index % 5}`,
      title: `Chat ${index}: switch speed`,
      harness: "claude",
      family: "claude",
      model: "claude-sonnet",
      status: "idle",
      turnCount: 3,
      updatedAt: START - index * 60_000,
      currentModeId: "default",
    };
    const events: Record<string, unknown>[] = [];
    const push = (dir: string, kind: string, msg: Record<string, unknown>) =>
      events.push({ sessionId, seq: events.length + 1, at: START + events.length * 1000, dir, kind, msg });
    const say = (text: string) =>
      push("in", "agent_message_chunk", {
        method: "session/update",
        params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
      });
    for (let turn = 0; turn < 3; turn += 1) {
      push("mux", "user_message", { text: `Turn ${turn}: how fast does chat ${index} open?` });
      push("mux", "turn_started", {});
      say(`Turn ${turn} of chat ${index}: the transcript draws from what the page holds.\n`);
      if (turn === 2) say(marker);
      push("mux", "turn_result", { status: "completed" });
    }
    return { sessionId, marker, listed, events, say };
  };
  const chats = [...Array(CHAT_COUNT).keys()].map(chat);
  // One completed turn fills more than a newest-page read. Its prompt must be prepared with
  // the read-ahead: otherwise the cached frame draws raw work, then attach folds that same work.
  const longChat = chats[CHAT_COUNT - 1]!;
  longChat.listed.family = "codex";
  longChat.listed.harness = "codex";
  longChat.listed.turnCount = 1;
  longChat.events.length = 0;
  const longEvent = (dir: string, kind: string, msg: Record<string, unknown>) => {
    const seq = longChat.events.length + 1;
    longChat.events.push({ sessionId: longChat.sessionId, seq, at: START + seq * 1000, dir, kind, msg });
  };
  longEvent("mux", "user_message", { text: "Keep this completed turn folded", promptId: "long-turn" });
  longEvent("mux", "turn_started", {});
  for (let index = 0; index < 420; index += 1)
    longEvent("in", "tool_call", {
      method: "session/update",
      params: {
        update: {
          sessionUpdate: "tool_call",
          toolCallId: `long-${index}`,
          title: `Inspect file ${index}`,
          kind: "read",
          status: "completed",
        },
      },
    });
  longChat.say(longChat.marker);
  longEvent("mux", "turn_result", { status: "completed" });
  let fullLongAttach = false;
  const byId = new Map(chats.map((entry) => [entry.sessionId, entry]));
  /// Every read the daemon answered, in order, for the test that reads them.
  const calls: { method: string; sessionId?: string }[] = [];
  /// Chats whose newest page the daemon answered a read-ahead for, and who waits on that.
  const readAhead = new Set<string>();
  const pendingReadAhead = new Set<string>();
  /// The page whose reads `readAhead` holds (`openPage` moves it on). A socket is tagged with the
  /// page that was current when it connected: an answer that reaches a page the test closed already
  /// (its read went out just before the close) is that page's, never the next one's. Counting it
  /// let a test switch before its own page had read the chat ahead, so the switch waited on the
  /// attach.
  let currentPage = 0;
  let staleReadAheads = 0;
  const readAheadWaiters = new Set<() => void>();

  function answer(method: string, params: Record<string, any>): unknown {
    const entry = byId.get(String(params.sessionId));
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: chats.map((c) => c.listed) };
      case "_acpmux/attach":
        if (entry === longChat && !fullLongAttach)
          return {
            session: entry.listed,
            lastSeq: entry.events.length,
            events: entry.events.slice(-400),
            hasMore: true,
            turnOpener: entry.events[0],
          };
        return { session: entry!.listed, lastSeq: entry!.events.length, events: entry!.events, hasMore: false };
      case "_acpmux/events": {
        if (!entry) return { events: [], hasMore: false, lastSeq: 0 };
        const all = entry.events as { seq: number; kind: string }[];
        // "transcript" is acpmux's group of every kind a transcript draws (paging.rs): every record here.
        const kinds =
          Array.isArray(params.kinds) && !params.kinds.includes("transcript")
            ? new Set<string>(params.kinds)
            : undefined;
        const after = typeof params.afterSeq === "number" ? params.afterSeq : 0;
        const before = typeof params.beforeSeq === "number" ? params.beforeSeq : Number.POSITIVE_INFINITY;
        const limit = typeof params.limit === "number" ? params.limit : 5_000;
        const matching = all.filter((e) => e.seq > after && e.seq < before && (!kinds || kinds.has(e.kind)));
        const newest = typeof params.beforeSeq === "number";
        const page = newest ? matching.slice(-limit) : matching.slice(0, limit);
        return { events: page, hasMore: page.length < matching.length, lastSeq: all.length };
      }
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: { page: currentPage } })
          ? undefined
          : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          calls.push({ method: message.method, sessionId: message.params?.sessionId });
          const result = answer(message.method, message.params ?? {});
          const reading = message.method === "_acpmux/events" && typeof message.params?.beforeSeq === "number";
          const readKey = `${(ws.data as { page: number }).page}:${message.id}`;
          if (reading) pendingReadAhead.add(readKey);
          setTimeout(
            () => {
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
              // A read ahead: an event page of the newest records, outside any attach.
              if (reading) {
                pendingReadAhead.delete(readKey);
                if ((ws.data as { page: number }).page !== currentPage) {
                  staleReadAheads += 1;
                  return;
                }
                readAhead.add(String(message.params?.sessionId));
                for (const waiter of readAheadWaiters) waiter();
              }
            },
            message.method === "_acpmux/attach" ? ATTACH_MS : CALL_MS,
          );
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
    console.log(`chat-switch-prefetch: ${staleReadAheads} read-ahead answers reached a page the test had closed`);
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Selects `sessionId` and answers the milliseconds from the select to the first painted frame
  /// whose transcript shows `marker` (null when none did within `limitMs`). Runs in the page.
  const switchTo = async ({ sessionId, marker, limitMs }: { sessionId: string; marker: string; limitMs: number }) => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const start = performance.now();
    const drawn = new Promise<number | null>((resolve) => {
      const stop = window.cmuxAfterPaint(() => {
        const at = performance.now() - start;
        if (scroller.innerText.includes(marker)) {
          resolve(at);
          return false;
        }
        if (at > limitMs) {
          resolve(null);
          return false;
        }
        return true;
      });
      void stop;
    });
    const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
      .cmuxAcpmuxActions;
    void actions?.["chat.select"]?.({ sessionId });
    return drawn;
  };
  const run = (page: Page, entry: (typeof chats)[number], limitMs = 6_000) =>
    page.evaluate(
      `(${switchTo.toString()})(${JSON.stringify({ sessionId: entry.sessionId, marker: entry.marker, limitMs })})`,
    ) as Promise<number | null>;
  const percentile = (values: number[], p: number) => {
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1)]!;
  };
  /// Resolves once the daemon answered a read-ahead of every chat in `entries` and the page has
  /// painted twice since (the answers are in, the frames that follow ran).
  const readAheadOf = async (page: Page, entries: (typeof chats)[number][]) => {
    const all = () =>
      entries.every((entry) => readAhead.has(entry.sessionId)) &&
      ![...pendingReadAhead].some((key) => key.startsWith(`${currentPage}:`));
    const answered = async () => {
      if (!all())
        await new Promise<void>((resolve, reject) => {
          const timeout = setTimeout(() => {
            readAheadWaiters.delete(check);
            reject(new Error(`no read-ahead of ${entries.filter((e) => !readAhead.has(e.sessionId)).length} chats`));
          }, 20_000);
          const check = () => {
            if (!all()) return;
            clearTimeout(timeout);
            readAheadWaiters.delete(check);
            resolve();
          };
          readAheadWaiters.add(check);
        });
    };
    await answered();
    await page.evaluate("window.cmuxPaintFrame().then(() => window.cmuxPaintFrame())");
    // A tail response can cause one opener read. Drain it if present; the unfixed baseline
    // makes no opener read and can still reach the measurement and report its swap numbers.
    await answered();
    await page.evaluate("window.cmuxPaintFrame().then(() => window.cmuxPaintFrame())");
  };
  const openPage = async (first: (typeof chats)[number]) => {
    // What the daemon read ahead belongs to the page that asked: each test opens its own.
    readAhead.clear();
    currentPage += 1;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 }, deviceScaleFactor: 2 });
    await installPaintedFrames(page);
    await page.goto(url(first.sessionId));
    await page.getByText(first.marker).waitFor({ timeout: 30_000 });
    return page;
  };

  test("the first switch to each recent chat draws from memory, before its attach answers", async () => {
    const page = await openPage(chats[0]!);
    try {
      await readAheadOf(page, chats.slice(1, 1 + RECENT));
      const times: number[] = [];
      for (const entry of chats.slice(1, 1 + RECENT)) {
        const drawn = await run(page, entry);
        expect(drawn).not.toBeNull();
        times.push(drawn!);
      }
      console.log(
        `chat-switch-prefetch: first switch to ${RECENT} recent chats, select → painted ms: ` +
          `p50 ${percentile(times, 50).toFixed(1)} p95 ${percentile(times, 95).toFixed(1)} ` +
          `max ${Math.max(...times).toFixed(1)} (all: ${times.map((t) => t.toFixed(0)).join(", ")})`,
      );
      for (const time of times) expect(time).toBeLessThan(SWITCH_DRAWN_MS);
    } finally {
      await page.close();
    }
  });

  test("a chat asked for ahead of the press (chat.prefetch) draws from memory", async () => {
    const page = await openPage(chats[0]!);
    try {
      const far = chats[CHAT_COUNT - 3]!;
      await page.evaluate(
        `window.cmuxAcpmuxActions?.["chat.prefetch"]?.(${JSON.stringify({ sessionId: far.sessionId })})`,
      );
      await readAheadOf(page, [far]);
      const drawn = await run(page, far);
      expect(drawn).not.toBeNull();
      expect(drawn!).toBeLessThan(SWITCH_DRAWN_MS);
    } finally {
      await page.close();
    }
  });

  test("what a chat said after it was read ahead lands from the attach", async () => {
    const page = await openPage(chats[0]!);
    try {
      const entry = chats[2]!;
      await readAheadOf(page, [entry]);
      const fresh = "Said after the read-ahead.";
      entry.say(fresh);
      const drawn = await run(page, entry);
      expect(drawn).not.toBeNull();
      expect(drawn!).toBeLessThan(SWITCH_DRAWN_MS);
      await page
        .locator(".acpmux-scroll")
        .getByText(fresh)
        .waitFor({ timeout: ATTACH_MS + 5_000 });
    } finally {
      await page.close();
    }
  });

  test("cold prefetched and warm capped turns keep their first painted layout through attach", async () => {
    let page = await openPage(chats[0]!);
    try {
      await page.evaluate(
        `window.cmuxAcpmuxActions?.["chat.prefetch"]?.(${JSON.stringify({ sessionId: longChat.sessionId })})`,
      );
      await readAheadOf(page, [longChat]);
      const measure = () =>
        page.evaluate(
          async ({ sessionId, marker }) => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const visible = () => scroller.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
            const snapshot = () => ({
              visible: visible(),
              composer: document.querySelector(".acpmux-composer")!.getBoundingClientRect().toJSON(),
              rows: [...scroller.querySelectorAll<HTMLElement>("[data-row-id]")].map((row) => {
                const rect = row.getBoundingClientRect();
                return {
                  id: row.dataset.rowId,
                  text: row.innerText,
                  top: rect.top,
                  left: rect.left,
                  width: rect.width,
                  height: rect.height,
                };
              }),
              scrollTop: scroller.scrollTop,
              scrollHeight: scroller.scrollHeight,
              width: scroller.clientWidth,
            });
            const shifts: { at: number; value: number }[] = [];
            const observe = (entries: PerformanceEntry[]) => {
              for (const entry of entries)
                // Recent-input entries still count: a click must not hide the subsequent swap.
                shifts.push({ at: entry.startTime, value: (entry as PerformanceEntry & { value: number }).value });
            };
            const observer = new PerformanceObserver((list) => observe(list.getEntries()));
            observer.observe({ type: "layout-shift" });
            const started = performance.now();
            const samples: { frame: number; at: number; view: ReturnType<typeof snapshot> }[] = [];
            let attachedAt: number | undefined;
            let stop = () => {};
            let fail: (reason: unknown) => void = () => {};
            let timeout: ReturnType<typeof setTimeout> | undefined;
            const measured = new Promise<void>((resolve, reject) => {
              fail = reject;
              timeout = setTimeout(
                () => reject(new Error("switch did not paint and finish attach within 8 seconds")),
                8_000,
              );
              stop = window.cmuxAfterPaint((frame) => {
                if (samples.length || (visible() && scroller.innerText.includes(marker)))
                  samples.push({ frame, at: performance.now() - started, view: snapshot() });
                // Cover attach plus a rendering opportunity for its asynchronous layout work.
                if (attachedAt !== undefined && frame > attachedAt && samples.length) {
                  resolve();
                  return false;
                }
                return true;
              });
            });
            try {
              const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
                .cmuxAcpmuxActions!;
              void actions["chat.select"]!({ sessionId })
                .then(async () => {
                  await window.cmuxPaintFrame();
                  attachedAt = await window.cmuxPaintFrame();
                })
                .catch(fail);
              await measured;
              observe(observer.takeRecords());
              const cached = samples[0]!;
              const final = samples.at(-1)!.view;
              const finalKey = JSON.stringify(final);
              const lastChanged = samples.reduce(
                (last, sample, index) => (JSON.stringify(sample.view) !== finalKey ? index : last),
                -1,
              );
              return {
                cached,
                final,
                sampleCount: samples.length,
                swapFrames: lastChanged + 1,
                shiftScore: shifts
                  // The first target frame replaces the previous chat. Its shift belongs to
                  // that deliberate switch, not a later movement of text already painted.
                  // LayoutShift timestamps fall after rAF, so use the post-paint observation.
                  .filter((shift) => shift.at > started + cached.at)
                  .reduce((sum, shift) => sum + shift.value, 0),
                allShiftScore: shifts.reduce((sum, shift) => sum + shift.value, 0),
              };
            } finally {
              clearTimeout(timeout);
              stop();
              observer.disconnect();
            }
          },
          { sessionId: longChat.sessionId, marker: longChat.marker },
        );
      const cold = await measure();
      await page.close();
      // The warm visit starts with all events loaded: its prompt was in the history, not stored
      // separately as turnOpener. Switching away must preserve it before capping that history.
      fullLongAttach = true;
      page = await openPage(longChat);
      fullLongAttach = false;
      await page.evaluate(
        `window.cmuxAcpmuxActions["chat.select"](${JSON.stringify({ sessionId: chats[0]!.sessionId })})`,
      );
      const warm = await measure();
      const out = process.env.FAST_CHECKS_OUT;
      if (out) {
        await Bun.write(path.join(out, "chat-switch-one-render.json"), JSON.stringify({ cold, warm }, null, 2));
        for (const theme of ["light", "dark"]) {
          await page.evaluate((theme) => (document.documentElement.dataset.theme = theme), theme);
          await page.evaluate(() => window.cmuxPaintFrame().then(() => window.cmuxPaintFrame()));
          await page.locator(".acpmux-scroll").screenshot({ path: path.join(out, `completed-turn-${theme}.png`) });
        }
      }
      for (const [mode, frames] of [
        ["cold-prefetched", cold],
        ["warm", warm],
      ] as const) {
        console.log(
          `chat-switch-one-render: ${JSON.stringify({
            mode,
            firstTextMs: frames.cached.at,
            swapFrames: frames.swapFrames,
            shiftScore: frames.shiftScore,
            allShiftScore: frames.allShiftScore,
            sampleCount: frames.sampleCount,
            firstScrollTop: frames.cached.view.scrollTop,
            finalScrollTop: frames.final.scrollTop,
            firstScrollHeight: frames.cached.view.scrollHeight,
            finalScrollHeight: frames.final.scrollHeight,
          })}`,
        );
      }
      for (const frames of [cold, warm]) {
        expect(frames.cached.at).toBeLessThan(SWITCH_DRAWN_MS);
        expect(frames.cached.view.rows.some((row) => row.id?.startsWith("worked-"))).toBe(true);
        expect(frames.swapFrames).toBe(0);
        expect(frames.shiftScore).toBe(0);
        expect(frames.final).toEqual(frames.cached.view);
      }
    } finally {
      fullLongAttach = false;
      await page.close();
    }
  });

  test("reading ahead never pushes a chat the reader opened out of the page's memory", async () => {
    const page = await openPage(chats[0]!);
    try {
      // Opened by the reader: far down the list, out of the read-ahead's reach.
      const visited = chats.slice(30, 34);
      for (const entry of visited) expect(await run(page, entry)).not.toBeNull();
      // Many reads ahead after them.
      for (const entry of chats.slice(40, 58))
        await page.evaluate(
          `window.cmuxAcpmuxActions?.["chat.prefetch"]?.(${JSON.stringify({ sessionId: entry.sessionId })})`,
        );
      await readAheadOf(page, chats.slice(40, 58));
      for (const entry of visited) {
        const drawn = await run(page, entry);
        expect(drawn).not.toBeNull();
        expect(drawn!).toBeLessThan(SWITCH_DRAWN_MS);
      }
    } finally {
      await page.close();
    }
  });
});
