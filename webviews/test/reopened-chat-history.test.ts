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
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
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
  ///
  /// Only that backwards page, which is every read a cold open makes. acpmux also serves a
  /// forward page (`afterSeq`, which `limit: 0` or no `newest` asks for, for a reconnect's missed
  /// events); this answers the newest page for one of those, so extend it before a test here
  /// reconnects or resumes.
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

  /// The chats this file opens. The first two are the reported shape — newest records heavy in
  /// bytes and light on screen, which leaves a cold open with almost nothing drawn — and
  /// `manyPastes` is the one that reds on the tree before the fix. `longText` is an ordinary long
  /// chat, held to the same promise so a future loader cannot buy the band back for the common
  /// case.
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
    // Many rowless pages in a row, with older turns behind them: one ask reads on past every one of
    // them (direct.ts OLDER_PAGES_PER_ASK) until a turn starts. A wall longer than one ask reads,
    // which moves `historyFrom` on a capped read so the transcript asks again (#22794), is
    // agent-pane-restore-long-turn.test.ts.
    pasteWall: history([
      ...Array.from({ length: 14 }, (_, at) => turn(at + 1)).flat(),
      ...Array.from({ length: 10 }, (_, at) => bigPaste(`q-${at + 1}`, 300)),
      ...Array.from({ length: 2 }, (_, at) => turn(at + 15)).flat(),
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
    // The chat's own turns. Load-bearing only in that a chat of none is a new chat, which draws
    // the hero instead of a transcript (`isNewChat`).
    turnCount: records().filter((record) => record.kind === "user_message").length,
    updatedAt: START,
    currentModeId: "default",
    modes: {
      currentModeId: "default",
      availableModes: [{ id: "default", name: "Manual", description: "Always ask before making changes" }],
    },
  });

  /// How long the stand-in daemon takes to answer. Zero here; a run can set
  /// CMUX_REOPEN_TEST_LATENCY_MS to stand in for a loaded CI runner.
  const LATENCY_MS = Number(process.env.CMUX_REOPEN_TEST_LATENCY_MS ?? 0);
  /// How much slower than this machine the renderer runs. One here;
  /// CMUX_REOPEN_TEST_THROTTLE=24 stands in for a CI VM with nothing left, where the gap between a
  /// reply and the read it starts runs into seconds — the timing a chat measured on a clock cannot
  /// survive, and what the gate below has to hold under.
  const THROTTLE = Number(process.env.CMUX_REOPEN_TEST_THROTTLE ?? 0);
  /// Requests the pane has out, and when the last one was answered: the daemon is what knows
  /// whether the pane is still reading the chat, where a count of still frames in the page only
  /// measures the gap between two round trips.
  let inFlight = 0;
  let answeredAt = 0;
  /// Whether the chat's oldest record has been served through a history read. Once it has, the
  /// chat has nothing older left (`historyExhausted`), so no later read can add a row above what
  /// is drawn: what the page holds then is the whole chat, whatever the timing was.
  let servedOldest = false;
  /// The waits on the daemon's answers: each answer wakes them.
  const waiting = new Set<() => void>();
  /// Resolves once `condition` holds, checked as the daemon answers each request; fails with
  /// `failure()` if it does not by `timeout`.
  const answered = (condition: () => boolean, timeout: number, failure: () => string) =>
    new Promise<void>((resolve, reject) => {
      const check = () => {
        if (!condition()) return;
        waiting.delete(check);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        waiting.delete(check);
        reject(new Error(failure()));
      }, timeout);
      waiting.add(check);
      check();
    });
  /// The pane has nothing out and has had an answer. This is never what decides that a chat has
  /// been read through: a pane with nothing out between two older pages is exactly the half-drawn
  /// chat Leo saw, and on a slow renderer the gap between a reply and the read it starts runs into
  /// seconds.
  const quiet = () =>
    answered(
      () => answeredAt !== 0 && inFlight === 0,
      25_000 + 20 * LATENCY_MS,
      () => `the pane kept asking acpmux: ${inFlight} in flight, last answer ${answeredAt}`,
    );

  let olderReads = 0;
  /// The byte caps the pane asked for, which is the whole of what bounds a page: acpmux caps one
  /// only when the client says to (`max_bytes`, paging.rs). A pane that stopped asking would be
  /// served every record at once, and this fixture would stop standing for a real chat, so what it
  /// asked for is checked below instead of assumed.
  const asked = new Set<number>();
  const bytes = (params: Record<string, any>): number | undefined => {
    if (params.maxBytes === undefined) return undefined;
    const max = Number(params.maxBytes);
    asked.add(max);
    return max;
  };
  /// The chat's oldest record is in this page, so the page it is served to holds history back to
  /// the first turn. Only the history reads count: the pane's by-kind probes can carry the oldest
  /// record too (`fetchTurnOpener` asks for `user_message`) without the transcript holding it.
  const serve = <T extends { events: Rec[] }>(page: T, isHistory: boolean): T => {
    if (isHistory && page.events.some((event) => event.seq === 1)) servedOldest = true;
    return page;
  };
  const answer = (method: string, params: Record<string, any>): unknown => {
    const all = records();
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        // The cap is the client's to set, as it is in acpmux (`max_bytes`): what the pane asks for
        // is what it gets, so a pane that stopped asking would be seen here.
        const page = serve(newestPage(all, Number.POSITIVE_INFINITY, Number(params.limit ?? 400), bytes(params)), true);
        return { session: summary(), lastSeq: all.length, events: page.events, hasMore: page.hasMore };
      }
      case "_acpmux/events": {
        const before = params.beforeSeq === undefined ? Number.POSITIVE_INFINITY : Number(params.beforeSeq);
        // The pane asks for `transcript` when paging older history, and by kind for the rest.
        const kinds: string[] | undefined = Array.isArray(params.kinds) ? params.kinds.map(String) : undefined;
        // Only the history reads: the pane's own probes before its page (the chat's slash commands,
        // `fetchCommands`; the open turn's opener, `fetchTurnOpener`, which asks by kind) carry a
        // `beforeSeq` too and are not the transcript's history.
        const isHistory = kinds?.includes("transcript") === true;
        if (params.beforeSeq !== undefined && isHistory) olderReads += 1;
        // `transcript` is every record of these chats: each `mux` kind here is in acpmux's
        // TRANSCRIPT_MUX_KINDS, and each `in` record carries a `session/update` method, which is
        // what `is_transcript` asks of one (paging.rs). So the filter has nothing to drop.
        const wanted = isHistory ? all : all.filter((record) => (kinds ? kinds.includes(record.kind) : true));
        const page = serve(newestPage(wanted, before, Number(params.limit ?? 400), bytes(params)), isHistory);
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
          inFlight += 1;
          // A loaded runner answers no faster than this; CMUX_REOPEN_TEST_LATENCY_MS makes a slow
          // one on purpose, to show that what is measured below does not depend on the speed of
          // the answers (a page measured between two reads is the shape of the bug itself).
          setTimeout(() => {
            try {
              ws.send(
                JSON.stringify({
                  jsonrpc: "2.0",
                  id: message.id,
                  result: answer(message.method, message.params ?? {}),
                }),
              );
            } finally {
              // Even a send that fails (a page closed with a read out) ends the request: a count
              // that leaked would stall every later pass.
              inFlight -= 1;
              answeredAt = Date.now();
              for (const wake of waiting) wake();
            }
          }, LATENCY_MS);
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

  /// How far the open has got: the rows the transcript holds, how much it can scroll, and the
  /// height the loader's own threshold is measured in.
  const progress = () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
    if (!scroller) return { rows: 0, scrollable: 0, view: 0 };
    return {
      rows: scroller.querySelectorAll(".acpmux-row").length,
      scrollable: scroller.scrollHeight - scroller.clientHeight,
      view: scroller.clientHeight,
    };
  };

  /// Waits until nothing the open is still doing can change what is measured below, by what has
  /// happened and not by how long ago. Either of two things is enough:
  ///
  /// - acpmux has served the chat's oldest record, so nothing older is left to read; or
  /// - the transcript holds six viewports of history, which is where the older-history loader
  ///   stops asking (`node.scrollTop >= node.clientHeight * OLDER_AHEAD_VIEWPORTS`, App.tsx). A view with that much
  ///   below it has been placed at its latest row and is pinned there as each page lands
  ///   (`didOpenAtLatest`, `settleFollowBottom`), so records arriving above the first row move the
  ///   rows above the reader and not the last one off the composer.
  ///
  /// This is the gate the time-based one has to replace. The dock and the scroller mount on the
  /// App's first render, long before the attach reply, and the gap between a reply and the read it
  /// starts is hundreds of milliseconds on a loaded runner and seconds on a throttled renderer —
  /// so a chat held still for a few frames, or quiet for a moment, is just as likely to be a chat
  /// caught mid-load, whose numbers are the bug's own (no rows, a band, nothing to scroll).
  ///
  /// False means the open never read through, which the test asserts and reports — but it measures
  /// first, so the failure names the band with Leo's numbers and not just the wait. The bounds are
  /// a deadline as well as a pass count, because one `evaluate` costs seconds on a throttled
  /// renderer and 600 of those would outlive the file's own timeout.
  const readThrough = async (page: Page) => {
    const until = Date.now() + 25_000 + 20 * LATENCY_MS;
    for (let pass = 0; pass < 600 && Date.now() < until; pass += 1) {
      const now = (await page.evaluate(`(${progress.toString()})()`)) as ReturnType<typeof progress>;
      if (now.rows > 0 && (servedOldest || now.scrollable > 6 * now.view)) return true;
      // The next look comes a frame later, once the page has drawn what it has.
      await page.evaluate(() => new Promise((resolve) => requestAnimationFrame(resolve)));
    }
    return false;
  };

  /// What the reopened chat shows once it has settled: the room the last message leaves above the
  /// composer, whether the view is at the bottom, and how much of the chat is in the transcript.
  const settled = async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
    const frame = () => window.cmuxPaintFrame();
    const count = () => scroller.querySelectorAll(".acpmux-row").length;
    // The chat has been read through before this runs (`readThrough`), so nothing in flight can
    // still add a row. This only waits for the last page to be laid out: the extent, the row count
    // and the offset stop changing for a few frames in a row.
    let was = "";
    for (let still = 0, passes = 0; still < 8; passes += 1) {
      if (passes > 1800) throw new Error(`the chat never settled: ${was}`);
      await frame();
      const now = `${scroller.scrollHeight}|${count()}|${scroller.scrollTop}`;
      still = now === was ? still + 1 : 0;
      was = now;
    }
    // The band is only the transcript's own to answer for while the composer floats over it
    // (`data-dock`); on the hero, a handoff review, the diff or Session Info the stack is in flow
    // and `.acpmux-dock` is `display: contents`, whose rect is all zeroes (bottomStack.css).
    const mode = document.querySelector<HTMLElement>(".acpmux-main")?.dataset.dock;
    if (mode !== "float") throw new Error(`the stage is not the transcript: data-dock=${mode}`);
    const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
    const last = rows.at(-1);
    if (!last) throw new Error("the chat drew no row");
    const view = scroller.getBoundingClientRect();
    return {
      rows: rows.length,
      // The blank band Leo saw: from the last row's bottom down to the composer's stack.
      lastLine: dock.getBoundingClientRect().top - last.getBoundingClientRect().bottom,
      atBottom: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      scrollable: scroller.scrollHeight - scroller.clientHeight,
      height: view.height,
      firstRowText: (rows[0]?.innerText ?? "").slice(0, 60).replace(/\s+/g, " "),
      lastRowText: (last?.innerText ?? "").slice(0, 60).replace(/\s+/g, " "),
    };
  };

  /// Holds the view at the top for a few frames, as a reader does with a trackpad, and answers
  /// what the transcript holds there. One pass; the reads it starts are waited for outside.
  const atTop = async () => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const frame = () => window.cmuxPaintFrame();
    for (let pass = 0; pass < 10; pass += 1) {
      scroller.scrollTop = 0;
      await frame();
    }
    const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
    return {
      rows: rows.length,
      firstRowText: (rows[0]?.innerText ?? "").slice(0, 80).replace(/\s+/g, " "),
      // The transcript's own text: a first turn echoed anywhere else on the page (a summary card,
      // a queue preview) is not the row this asks about.
      reachedFirstTurn: scroller.innerText.includes("Lane report 1:"),
    };
  };

  /// Scrolls up until the first turn is in the transcript, or until the chat has nothing older
  /// left to give. Holding the top asks for one more page, so each pass waits for that page to be
  /// answered before it looks again — and a top that has not moved is never itself taken for the
  /// end of the history, because that is what a loader needing another ask looks like (#22794). A
  /// pass whose hold asked for nothing while older history is left ends the scroll: the loader
  /// stopped asking, and the first turn is not reached.
  const scrollToOldest = async (page: Page) => {
    let before = olderReads;
    let reached = (await page.evaluate(`(${atTop.toString()})()`)) as Awaited<ReturnType<typeof atTop>>;
    for (let pass = 0; pass < 60 && !reached.reachedFirstTurn; pass += 1) {
      const read = () => servedOldest || (olderReads > before && inFlight === 0);
      const pageCame = await answered(read, 10_000 + 20 * LATENCY_MS, () => "no older read").then(
        () => true,
        () => false,
      );
      if (!pageCame) break;
      before = olderReads;
      reached = (await page.evaluate(`(${atTop.toString()})()`)) as Awaited<ReturnType<typeof atTop>>;
    }
    return reached;
  };

  const openChat = async (name: ChatName) => {
    chat = name;
    olderReads = 0;
    servedOldest = false;
    answeredAt = 0;
    asked.clear();
    const page = await browser!.newPage({ viewport: { width: 1000, height: 820 } });
    await installPaintedFrames(page);
    if (THROTTLE > 1) {
      const cdp = await page.context().newCDPSession(page);
      await cdp.send("Emulation.setCPUThrottlingRate", { rate: THROTTLE });
    }
    await page.goto(url());
    // The pane has drawn the chat, not just its frame, before anything is measured: a row of the
    // transcript, which only a reply from acpmux can put there.
    await page.locator(".acpmux-scroll .acpmux-row").first().waitFor({ timeout: 25_000 });
    return page;
  };

  for (const name of Object.keys(CHATS) as ChatName[]) {
    test(`a reopened ${name} chat shows its history under the composer, with no blank band`, async () => {
      const page = await openChat(name);
      // Nothing is measured until the open has read what it is going to read: a chat caught
      // between two older pages is the half-drawn chat Leo saw, and reporting that would call the
      // bug on a tree that does not have it.
      const through = await readThrough(page);
      await quiet();
      const state = (await page.evaluate(`(${settled.toString()})()`)) as Awaited<ReturnType<typeof settled>>;
      const reached = await scrollToOldest(page);
      await page.close();
      console.log(`reopened-chat-history ${name}: settled ${JSON.stringify(state)}, read through ${through}`);
      console.log(`reopened-chat-history ${name}: top ${JSON.stringify(reached)}, older reads ${olderReads}`);

      // What bounded the pages above was the pane's own asking, as it is with acpmux.
      expect([...asked].sort((a, b) => a - b)).toEqual([OPEN_BYTES, OLDER_BYTES]);
      // The transcript holds rows of its own, not an empty frame. This counts the rows mounted in
      // the virtualized list, so it cannot tell a whole chat from its last messages — Leo's "only
      // the last messages" is what `reachedFirstTurn` below answers.
      expect(state.rows).toBeGreaterThan(0);
      // Leo: "a big blank gap between the transcript and the composer".
      expect(state.lastLine).toBeLessThan(LAST_LINE_MAX);
      // Not buried under the composer either. Loose by a few pixels: the dock floats over the
      // transcript's foot and the transcript reserves exactly its height, so the last row's bottom
      // lands on the dock's top give or take subpixel residue, which moves with the font metrics.
      expect(state.lastLine).toBeGreaterThan(-8);
      // Opened on the newest message, not scrolled off it. A transcript too short to scroll is 0
      // here as well, so this bounds the overscroll; the band and the scroll below are what say
      // the history is there.
      expect(state.atBottom).toBeLessThan(2);
      // Leo: "no older history, and he could not scroll up". The chat scrolls at all — which the
      // gate above already needs for the chats it lets through on their extent, so the turn
      // reached below is the half that answers him.
      expect(state.scrollable).toBeGreaterThan(0);
      expect(reached.reachedFirstTurn).toBe(true);
      // Named last so a chat that never read through fails on the band first, and on this after.
      expect(through).toBe(true);
    });
  }
});
