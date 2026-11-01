// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The rest gap: the room between the chat's newest row (its last drawn line, or its footer's action
// row when it has one) and the top of the bottom stack (the running tray when it shows, else the
// composer card). Leo, 2026-11-01: "in the next build, will we have more space between composer and
// latest messages? i'd like it... tho maybe not as much as claude code". And: "there's currently some
// oddities where the gap between recent text and composer is bigger than the desired gap ... so
// there's no shift on load and it's just a load".
//
// The gap is REST_GAP (model.ts, 56px) in every state the reader sees the chat's end in: at rest, while a
// reply streams, after the composer grows two lines, with the running tray shown, and on every
// painted frame of a chat's load. Before: 16px (the last row's turn gap alone), and a streamed line
// was drawn up to 34px under the composer's top before it rose.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { REST_GAP } from "../src/agent-session/acpmux/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-composer-rest-gap.test.ts", async () => {
  setDefaultTimeout(200_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-composer-rest-gap: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer rest gap", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d4";
  let status = "idle";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Retry policy",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 6,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  const LAST = "Rest gap ending marker.";
  // History taller than the view, so the chat opens at its latest row over the composer.
  for (let turn = 0; turn < 6; turn++) {
    record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops ` +
          "after five attempts. The fetch tests cover a server that fails twice and then answers." +
          (turn === 5 ? ` ${LAST}` : ""),
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  const opened = events.length;

  // A second chat, still running, as Leo's was when he saw the load shift: a rich write-up (headings,
  // code, tables: each laid out at its own height as it mounts, over its estimate) and a subagent
  // running, so the tray is in the bottom stack as the chat opens.
  const BUSY = "0190a000-0000-7000-8000-0000000000d5";
  const BUSY_LAST = "Busy ending marker.";
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const busySteps: Step[] = [
    ["mux", "user_message", { text: "Write up the retry policy", promptId: "b-0" }],
    ["mux", "turn_started", {}],
    ...Array.from({ length: 8 }, (_, index): Step => [
      "in",
      "agent_message_chunk",
      chunk(
        `## Part ${index + 1}\n\nEach retry waits longer than the last and adds jitter.\n\n` +
          `\`\`\`ts\nconst delay${index} = base * 2 ** attempt + jitter();\nawait sleep(delay${index});\n\`\`\`\n\n` +
          "| attempt | delay |\n| --- | --- |\n| 1 | 200 ms |\n| 2 | 400 ms |\n\n- waits longer\n- adds jitter\n\n",
      ),
    ]),
    ["in", "agent_message_chunk", chunk(BUSY_LAST)],
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned" },
        { subagents: [{ id: "busy-a1", parent: null, name: "Reviewer", state: "running" }] },
      ),
    ],
  ];
  const busy = busySteps.map(([dir, kind, msg], index) => ({ sessionId: BUSY, seq: index + 1, at: Date.now(), dir, kind, msg }));
  const busySummary = () => ({ ...summary(), sessionId: BUSY, title: "Retry write-up", status: "running", turnCount: 1 });

  function answer(method: string, params: { sessionId?: string }): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary(), busySummary()] };
      case "_acpmux/attach":
        if (params.sessionId === BUSY) return { session: busySummary(), lastSeq: busy.length, events: busy };
        return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        if (params.sessionId === BUSY) return { events: [], hasMore: false, lastSeq: busy.length };
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let socket: { send(data: string): void } | undefined;
  const emit = (dir: string, kind: string, msg: Record<string, unknown>) =>
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
  const changed = () =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
      }),
    );
  const WORDS = "the client waits a little longer before each retry and adds random jitter so a crowd does not retry in step".split(
    " ",
  );

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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { sessionId?: string } };
          if (message.method === "_acpmux/attach" && message.params?.sessionId !== BUSY) socket = ws;
          if (message.id !== undefined)
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
    // A cold dev server's first load can run Vite's dependency optimizer and reload mid-compile.
    for (const browser of browsers.values()) {
      for (let attempt = 1; ; attempt++) {
        const warm = await browser.newPage();
        try {
          await warm.goto(url());
          await warm.getByText(LAST).waitFor({ timeout: 25_000 });
          await warm.close();
          break;
        } catch (error) {
          await warm.close();
          if (attempt === 3) throw error;
        }
      }
    }
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  const url = (session = SESSION) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };

  /// Installed before the page's own scripts. `__restGap()` reads the gap as laid out now: the stack's
  /// top (its first drawn part: the tray, a queue, or the composer card) less the bottom of the newest
  /// row's line (its action row or live line; not the turn gap the row keeps). `__frames` holds it
  /// for every painted frame from the first that draws both: read in a ResizeObserver made after the
  /// pane's own observers (which place the rows and the room under them before paint), on a probe
  /// resized in each frame's callbacks, so each read is of the layout that frame paints.
  const sampler = () => {
    const w = window as unknown as {
      __restGap: () => number | undefined;
      __frames: { t: number; gap: number }[];
    };
    /// Where the newest row's line ends: its box less the turn gap every last row keeps (16px,
    /// `--cv-turn-gap`). A turn's footer keeps that gap under its 24px action row; the running turn's
    /// live line keeps it over its line, so the two swap at a turn's end without moving anything.
    const TURN_GAP = 16;
    const contentBottom = (row: Element) => row.getBoundingClientRect().bottom - TURN_GAP;
    /// The top of the bottom stack's first drawn part: the tray, a question, the queue or the card.
    const stackTop = (dock: Element) => {
      const parts = [...dock.children].flatMap((part) =>
        part.classList.contains("acpmux-composer") ? [...part.children] : [part],
      );
      const tops = parts.map((part) => part.getBoundingClientRect()).filter((rect) => rect.height > 0);
      return tops.length ? Math.min(...tops.map((rect) => rect.top)) : undefined;
    };
    w.__restGap = () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const dock = document.querySelector<HTMLElement>(".acpmux-main[data-dock=float] > .acpmux-dock");
      if (!scroller || !dock) return undefined;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter(
        (row) => row.getBoundingClientRect().height > 0,
      );
      if (!rows.length) return undefined;
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const bottom = contentBottom(last);
      const top = stackTop(dock);
      return bottom === undefined || top === undefined ? undefined : top - bottom;
    };
    w.__frames = [];
    const start = () => {
      if (!document.querySelector(".acpmux-scroll .acpmux-row") || !document.querySelector(".acpmux-dock")) return false;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
      document.body.append(probe);
      new ResizeObserver(() => {
        const gap = w.__restGap();
        if (gap !== undefined) w.__frames.push({ t: Math.round(performance.now()), gap: Math.round(gap * 10) / 10 });
      }).observe(probe);
      let wide = false;
      const frame = () => {
        wide = !wide;
        probe.style.width = wide ? "2px" : "1px";
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
      return true;
    };
    // The first rows mount in a React commit whose layout effects make the pane's observers; this
    // observer's callback runs after that commit, so the probe's observer comes after the pane's.
    const mutations = new MutationObserver(() => {
      if (start()) mutations.disconnect();
    });
    mutations.observe(document, { childList: true, subtree: true });
  };

  async function open(name: string, session = SESSION, marker = LAST) {
    // Each page attaches to the same history: what an earlier page streamed is not part of it.
    events.length = opened;
    status = "idle";
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(sampler);
    await page.goto(url(session));
    await page.getByText(marker).waitFor();
    await page.mouse.move(0, 0);
    await rest(page);
    return page;
  }

  /// Resolves once the transcript's offset has held, with nothing in it animating, for 8 frames.
  const rest = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const moving = () =>
        document
          .getAnimations()
          .some(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      let last = NaN;
      for (let held = 0, frames = 0; held < 8 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const still = scroller.scrollTop === last && !moving();
        held = still ? held + 1 : 0;
        last = scroller.scrollTop;
      }
    });
  const gap = (page: Page) =>
    page.evaluate(() => (window as unknown as { __restGap: () => number | undefined }).__restGap());
  const frames = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: { t: number; gap: number }[] };
      const taken = w.__frames;
      w.__frames = [];
      return taken;
    });
  /// The frames whose gap is not `want`, within a pixel: a composer line is fractional (22.75px), and
  /// the rows' lift by its growth is whole pixels.
  const off = (taken: { t: number; gap: number }[], want: number) =>
    taken.filter((frame) => Math.abs(frame.gap - want) > 1).map((frame) => `${frame.t}ms: ${frame.gap}px`);
  /// The frames of a streaming reply whose gap leaves (0, want]: a new line drawn under the stack's top,
  /// or the rows dropping below where they rest. A line that wraps rises into the gap's room over a
  /// few frames (followGlide.ts), so a frame may sit inside the gap but never past either edge.
  const outside = (taken: { t: number; gap: number }[], want: number) =>
    taken.filter((frame) => frame.gap <= 0 || frame.gap > want + 1).map((frame) => `${frame.t}ms: ${frame.gap}px`);

  test.each(engines.map(([name]) => name))("%s: a chat loads with the rest gap on every painted frame", async (name) => {
    const page = await open(name);
    const settled = await gap(page);
    const taken = await frames(page);
    const shifted = off(taken, settled!);
    console.log(`${name} load: settled ${settled}px over ${taken.length} frames; ${shifted.length} shift frames: ${shifted.slice(0, 8).join(", ")}`);
    expect(taken.length).toBeGreaterThan(0);
    expect(Math.abs(settled! - REST_GAP)).toBeLessThanOrEqual(1);
    expect(shifted).toEqual([]);
    await page.close();
  });

  test.each(engines.map(([name]) => name))(
    "%s: a running chat with rich history and the tray loads with the rest gap on every painted frame",
    async (name) => {
      const page = await open(name, BUSY, BUSY_LAST);
      await page.locator(".acpmux-running-tray").waitFor({ timeout: 20_000 });
      await rest(page);
      const settled = await gap(page);
      const taken = await frames(page);
      const shifted = off(taken, settled!);
      console.log(`${name} busy load: settled ${settled}px over ${taken.length} frames; ${shifted.length} shift frames: ${shifted.slice(0, 8).join(", ")}`);
      expect(taken.length).toBeGreaterThan(0);
      expect(Math.abs(settled! - REST_GAP)).toBeLessThanOrEqual(1);
      expect(shifted).toEqual([]);
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: the rest gap holds while a reply streams, with the tray shown, and after the composer grows",
    async (name) => {
      const page = await open(name);
      // Every state is read before any is asserted, so one run shows them all.
      const seen: Record<string, number | undefined> = {};
      const shifts: Record<string, string[]> = {};
      // (a) At rest.
      seen.rest = await gap(page);
      await frames(page);

      // (b) A reply streams, followed: every frame from its first row keeps the gap.
      status = "running";
      emit("mux", "user_message", { text: "Now write it up", promptId: "p-stream" });
      emit("mux", "turn_started", {});
      changed();
      emit("in", "agent_message_chunk", chunk("Streaming marker. "));
      await page.getByText("Streaming marker.").waitFor();
      await rest(page);
      await frames(page);
      for (let index = 0; index < 40; index++) {
        emit("in", "agent_message_chunk", chunk(`${WORDS.slice(index % 7, (index % 7) + 4).join(" ")} `));
        // fixed-wait: the stream's own cadence, a chunk every frame or two as an agent sends them, is the input under test.
        await Bun.sleep(16 + (index % 3) * 10);
      }
      await rest(page);
      const streamed = await frames(page);
      console.log(`${name} streaming: ${streamed.length} frames, gaps ${[...new Set(streamed.map((f) => f.gap))].join(", ")}`);
      seen.streaming = await gap(page);
      shifts.streaming = outside(streamed, REST_GAP);

      // (d) The running tray comes into the stack over the composer: the rows keep the gap above it.
      emit(
        "in",
        "subagent_spawned",
        update(
          { sessionUpdate: "subagent_spawned" },
          { subagents: [{ id: "a1", parent: null, name: "Reviewer", state: "running" }] },
        ),
      );
      await page.locator(".acpmux-running-tray").waitFor({ timeout: 20_000 });
      await rest(page);
      const trayed = await frames(page);
      const trayTop = await page.evaluate(() => document.querySelector(".acpmux-running-tray")!.getBoundingClientRect().top);
      const card = await page.evaluate(() => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().top);
      expect(trayTop).toBeLessThan(card);
      console.log(`${name} tray: ${trayed.length} frames, gaps ${[...new Set(trayed.map((f) => f.gap))].join(", ")}`);
      seen.tray = await gap(page);
      // The frame the tray first draws in places the rows above it in that same frame.
      shifts.tray = off(trayed, REST_GAP);

      // (c) The composer grows two lines: the rows keep the gap above the taller stack.
      await page.locator(".acpmux-md").click();
      await page.keyboard.type("Then document the cap");
      for (let line = 0; line < 2; line++) {
        await page.keyboard.press("Shift+Enter");
        await page.keyboard.type(`and line ${line + 2} of the note`);
      }
      await rest(page);
      const grown = await frames(page);
      console.log(`${name} grown: ${grown.length} frames, gaps ${[...new Set(grown.map((f) => f.gap))].join(", ")}`);
      seen.grown = await gap(page);
      shifts.grown = off(grown, REST_GAP);

      emit("mux", "turn_result", { status: "completed" });
      status = "idle";
      changed();
      await page.close();
      console.log(`${name} states: ${JSON.stringify(seen)} shifts: ${JSON.stringify(shifts)}`);
      // (a) at rest, (b) streaming, (d) with the tray, (c) after the composer grew two lines.
      for (const state of ["rest", "streaming", "tray", "grown"])
        expect([state, Math.abs((seen[state] ?? NaN) - REST_GAP) <= 1]).toEqual([state, true]);
      for (const state of ["streaming", "tray", "grown"]) expect([state, shifts[state]]).toEqual([state, []]);
    },
  );
});
