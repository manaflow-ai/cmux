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
  const byId = new Map(chats.map((entry) => [entry.sessionId, entry]));
  /// Every read the daemon answered, in order, for the test that reads them.
  const calls: { method: string; sessionId?: string }[] = [];
  /// Chats whose newest page the daemon answered a read-ahead for, and who waits on that.
  const readAhead = new Set<string>();
  const readAheadWaiters = new Set<() => void>();

  function answer(method: string, params: Record<string, any>): unknown {
    const entry = byId.get(String(params.sessionId));
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: chats.map((c) => c.listed) };
      case "_acpmux/attach":
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
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          calls.push({ method: message.method, sessionId: message.params?.sessionId });
          const result = answer(message.method, message.params ?? {});
          setTimeout(
            () => {
              ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
              // A read ahead: an event page of the newest records, outside any attach.
              if (message.method === "_acpmux/events" && typeof message.params?.beforeSeq === "number") {
                readAhead.add(String(message.params.sessionId));
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
    const all = () => entries.every((entry) => readAhead.has(entry.sessionId));
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
    await page.evaluate("window.cmuxPaintFrame().then(() => window.cmuxPaintFrame())");
  };
  const openPage = async (first: (typeof chats)[number]) => {
    // What the daemon read ahead belongs to the page that asked: each test opens its own.
    readAhead.clear();
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
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
