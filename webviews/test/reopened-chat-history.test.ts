// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
// cmux-web-test-timeout: 300
//
// Leo, 2026-10-21: he reopened a closed chat (the coordinator's, claude-sr2) and got a big blank
// gap between the transcript and the composer, with only the last messages in it: no older
// history, and he could not scroll up.
//
// A reopened closed tab is an ordinary COLD chat: closing it released its page and its wake state
// (AgentTabs+Lifecycle.swift release), so it comes back as a fresh handshake naming the session,
// then connect and attach. So what it shows is one attach page, and acpmux ends a page before its
// records' JSON passes `maxBytes` (hub/paging.rs events_page, 128 KiB for an open), always keeping
// at least one record. A coordinator chat holds records that are huge in bytes and tiny on screen
// — a prompt queued with a big paste (up to 4 MB), a tool run with long output — so its page can
// be a single record that draws no transcript row at all. Everything else has to arrive through
// the older-history loader.
//
// These open such a chat in the real pane page and hold it to what a reopened chat owes the reader:
// the last message sits just above the composer (no blank band), and scrolling up reaches the
// chat's first turn.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("reopened-chat-history.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("reopened-chat-history: skipping (run `bunx playwright install chromium`)");
    describe.skip("reopened chat history", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e1";
  const START = Date.UTC(2026, 9, 21, 9, 0, 0);
  /// The caps acpmux applies to an open and to each older page (direct.ts OPEN_PAGE_BYTES,
  /// OLDER_PAGE_BYTES).
  const OPEN_BYTES = 128 * 1024;
  const OLDER_BYTES = 256 * 1024;
  /// The most room the last message may leave above the composer once the chat has settled. The
  /// transcript's own bottom rhythm is a row gap plus the dock's padding; a blank band is many
  /// times that.
  const LAST_LINE_MAX = 96;

  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  type Rec = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };

  const say = (text: string) => ({
    method: "session/update",
    params: { sessionId: CHAT, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
  });
  /// One finished turn of the coordinator's chat: a lane's report in, an answer back.
  const turn = (n: number): Step[] => [
    ["mux", "user_message", { text: `Lane report ${n}: the gallery render landed.`, promptId: `p-${n}` }],
    ["mux", "turn_started", {}],
    ["in", "agent_message_chunk", say(`Answer ${n}. Noted, and the next item is yours.`)],
    ["mux", "turn_result", { stopReason: "end_turn" }],
  ];
  /// A prompt queued with a big paste: kilobytes of JSON, and no transcript row of its own.
  const bigPaste = (id: string, kb: number): Step => ["mux", "queued", { promptId: id, text: "x".repeat(kb * 1024) }];

  const history = (steps: Step[]): Rec[] =>
    steps.map(([dir, kind, msg], index) => ({
      sessionId: CHAT,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));

  /// acpmux's `events_page` (hub/paging.rs): the newest records before `beforeSeq` that match
  /// `kinds`, ending before their JSON passes `maxBytes`, and always at least one record.
  const newestPage = (records: Rec[], beforeSeq: number, limit: number, maxBytes: number | undefined) => {
    const events: Rec[] = [];
    let bytes = 0;
    let hasMore = false;
    for (const event of records.filter((record) => record.seq < beforeSeq).reverse()) {
      if (events.length === limit) {
        hasMore = true;
        break;
      }
      bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
      if (maxBytes !== undefined && events.length > 0 && bytes > maxBytes) {
        hasMore = true;
        break;
      }
      events.push(event);
    }
    return { events: events.reverse(), hasMore };
  };

  /// The chats this file opens. Each is a long chat whose newest records are heavy in bytes and
  /// light on screen, the shape that leaves a cold open with almost nothing drawn.
  const CHATS = {
    // The newest record alone passes the open's cap, so the attach page is that one record — and
    // it draws no transcript row (it is a queued prompt, which belongs to the composer's stack).
    queuedPaste: history([...Array.from({ length: 14 }, (_, at) => turn(at + 1)).flat(), bigPaste("q-1", 160)]),
    // Several big pastes in a row: every older page is one of them, so the loader has to ask more
    // than once before any row appears.
    manyPastes: history([
      ...Array.from({ length: 14 }, (_, at) => turn(at + 1)).flat(),
      bigPaste("q-1", 300),
      bigPaste("q-2", 300),
      bigPaste("q-3", 300),
    ]),
    // No oversized record: a plain long chat, well past the open's cap in total.
    longText: history(
      Array.from(
        { length: 40 },
        (_, at) =>
          [
            [
              "mux",
              "user_message",
              { text: `Lane report ${at + 1}: ${"detail ".repeat(400)}`, promptId: `p-${at + 1}` },
            ],
            ["mux", "turn_started", {}],
            ["in", "agent_message_chunk", say(`Answer ${at + 1}. ${"and the rest of it ".repeat(400)}`)],
            ["mux", "turn_result", { stopReason: "end_turn" }],
          ] as Step[],
      ).flat(),
    ),
  };
  type ChatName = keyof typeof CHATS;
  let chat: ChatName = "queuedPaste";
  const records = () => CHATS[chat];

  const summary = () => ({
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "coordinator",
    harness: "claude",
    family: "claude",
    model: "claude-opus",
    status: "idle",
    turnCount: 14,
    updatedAt: START,
    currentModeId: "default",
    modes: {
      currentModeId: "default",
      availableModes: [{ id: "default", name: "Normal", description: "Ask before edits and commands" }],
    },
  });

  let olderReads = 0;
  const answer = (method: string, params: Record<string, any>): unknown => {
    const all = records();
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        const page = newestPage(all, Number.POSITIVE_INFINITY, Number(params.limit ?? 400), OPEN_BYTES);
        return { session: summary(), lastSeq: all.length, events: page.events, hasMore: page.hasMore };
      }
      case "_acpmux/events": {
        const before = params.beforeSeq === undefined ? Number.POSITIVE_INFINITY : Number(params.beforeSeq);
        if (params.beforeSeq !== undefined) olderReads += 1;
        // The pane asks for `transcript` when paging older history, and by kind for the rest.
        const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds.map(String) : undefined;
        const wanted = kinds?.includes("transcript")
          ? all
          : all.filter((record) => (kinds ? kinds.includes(record.kind) : true));
        const page = newestPage(wanted, before, Number(params.limit ?? 400), OLDER_BYTES);
        return { events: page.events, hasMore: page.hasMore, lastSeq: all.length };
      }
      default:
        return null;
    }
  };

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open() {},
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Answer 14.").waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    void daemon?.stop(true);
  });

  /// What the reopened chat shows once it has settled: the room the last message leaves above the
  /// composer, whether the view is at the bottom, and how much of the chat is in the transcript.
  const settled = async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
    const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
    // Settled: the extent and the row count stop changing for a few frames in a row (older pages
    // keep landing for a while after the first paint).
    let was = "";
    for (let still = 0, passes = 0; still < 8 && passes < 600; passes += 1) {
      await frame();
      const now = `${scroller.scrollHeight}|${scroller.querySelectorAll(".acpmux-row").length}|${scroller.scrollTop}`;
      still = now === was ? still + 1 : 0;
      was = now;
    }
    const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
    const last = rows.at(-1);
    const view = scroller.getBoundingClientRect();
    return {
      rows: rows.length,
      // The blank band Leo saw: from the last row's bottom down to the composer's stack.
      lastLine: last ? dock.getBoundingClientRect().top - last.getBoundingClientRect().bottom : null,
      atBottom: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      scrollable: scroller.scrollHeight - scroller.clientHeight,
      height: view.height,
      firstRowText: (rows[0]?.innerText ?? "").slice(0, 60).replace(/\s+/g, " "),
      lastRowText: (last?.innerText ?? "").slice(0, 60).replace(/\s+/g, " "),
    };
  };

  /// Scrolls to the top repeatedly, as a reader does with a trackpad, letting older pages land,
  /// and answers the oldest prompt the transcript holds.
  const scrollToOldest = async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const frame = () => new Promise<number>((resolve) => requestAnimationFrame(resolve));
    let oldest = "";
    for (let pass = 0; pass < 400; pass += 1) {
      scroller.scrollTop = 0;
      await frame();
      await frame();
      const first = scroller.querySelector<HTMLElement>(".acpmux-row");
      const text = (first?.innerText ?? "").replace(/\s+/g, " ").slice(0, 40);
      // At the top with no newer first row for a while: the chat has nothing older left.
      if (text === oldest && pass > 12 && scroller.scrollTop <= 1) break;
      oldest = text;
    }
    const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
    return {
      rows: rows.length,
      firstRowText: (rows[0]?.innerText ?? "").slice(0, 80).replace(/\s+/g, " "),
      reachedFirstTurn: document.body.innerText.includes("Lane report 1:"),
    };
  };

  const openChat = async (name: ChatName) => {
    chat = name;
    olderReads = 0;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 820 } });
    await page.goto(url());
    // The pane draws the chat (its loading state is over) before anything is measured.
    await page.waitForFunction(() => document.querySelector(".acpmux-dock") !== null);
    return page;
  };

  for (const name of ["queuedPaste", "manyPastes", "longText"] as ChatName[]) {
    test(`a reopened ${name} chat shows its history under the composer, with no blank band`, async () => {
      const page = await openChat(name);
      const state = (await page.evaluate(`(${settled.toString()})()`)) as Awaited<ReturnType<typeof settled>>;
      const reached = (await page.evaluate(`(${scrollToOldest.toString()})()`)) as Awaited<
        ReturnType<typeof scrollToOldest>
      >;
      await page.close();
      console.log(`reopened-chat-history ${name}: settled ${JSON.stringify(state)}`);
      console.log(`reopened-chat-history ${name}: top ${JSON.stringify(reached)}, older reads ${olderReads}`);

      // Leo: "only the last messages" — the chat's own turns are drawn, not an empty transcript.
      expect(state.rows).toBeGreaterThan(0);
      // Leo: "a big blank gap between the transcript and the composer".
      expect(state.lastLine).not.toBeNull();
      expect(state.lastLine!).toBeLessThan(LAST_LINE_MAX);
      expect(state.lastLine!).toBeGreaterThan(-1);
      // Pinned to the bottom: the newest message is what a reopened chat opens on.
      expect(state.atBottom).toBeLessThan(2);
      // Leo: "no older history, and he could not scroll up" — the chat scrolls, and scrolling up
      // reaches its first turn.
      expect(state.scrollable).toBeGreaterThan(0);
      expect(reached.reachedFirstTurn).toBe(true);
    });
  }
});
