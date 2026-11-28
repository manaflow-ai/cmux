// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// No two transcript rows ever draw over each other while a reply streams, under lag too (Leo,
// 2026-11-11: "when the text comes in. esp when it's lagging, there's a breif moment where ther'es
// overlapping text between the sent out text (from you) and the subequent tool calls/thinking").
// A reply streams text, thinks, calls a tool, streams more and thinks again, while the page's main
// thread is kept busy (a long task every few frames, as a loaded Mac's WebKit sees), in a chat that
// follows its latest line and in one the reader scrolled up a little. On every painted frame, read
// as the frame paints it (paintedFrames.ts), the ink of each row's text (and of the old words a
// status line leaves while they go) is compared with the next row's: no row's text may cross the
// next row's. Where the rows' boxes cross is reported too.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon. Both engines the app uses (WebKit draws the pane in cmux NEXT); one not installed skips.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { envelope } from "../src/agent-session/acpmux/incomingFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-stream-row-overlap.test.ts", async () => {
  setDefaultTimeout(240_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `agent-pane-stream-row-overlap: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("stream row overlap", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d1";
  let status = "idle";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Overlap",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 1,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const thought = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  // History that fills the view, so the chat opens at its latest line.
  record("mux", "user_message", { text: "Say a lot", promptId: "p-0" });
  record("mux", "turn_started", {});
  for (let index = 0; index < 14; index++)
    record(
      "in",
      "agent_message_chunk",
      chunk(`Opening paragraph ${index}. Words that fill the view with history.\n\n`),
    );
  record("mux", "turn_result", { status: "completed" });
  const opened = events.length;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
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
        params: { sessionId: SESSION, session: summary(), kind: "queue", seq: events.length },
      }),
    );
  const toolCall = (id: string, command: string) =>
    emit(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command },
      }),
    );
  const toolDone = (id: string) =>
    emit(
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "a\nb\n" } }],
        rawOutput: { exit_code: 0 },
      }),
    );
  const WORDS =
    "the client waits a little longer before each retry and adds random jitter so a crowd does not retry in step".split(
      " ",
    );
  // fixed-wait: the stream's own cadence, bursts a frame or two apart as an agent sends them, is the input under test.
  const pause = (ms: number) => Bun.sleep(ms);
  /// Words a few at a time, wrapping onto new lines as they come.
  async function words(count: number) {
    for (let index = 0; index < count; index++) {
      const text = WORDS.slice(index % 7, (index % 7) + 4).join(" ");
      emit("in", "agent_message_chunk", chunk(`${text}${index % 18 === 17 ? ".\n\n" : " "}`));
      await pause(14 + (index % 3) * 9);
    }
  }
  /// One turn as an agent sends it: text, a think, a tool call, more text, a think, a second call
  /// that lands right after the text, the rest of the reply.
  async function turn(id: string, early: () => Promise<unknown> = async () => {}) {
    status = "running";
    emit("mux", "user_message", { text: `Overlap turn ${id}`, promptId: `p-${id}` });
    emit("mux", "turn_started", {});
    changed();
    await pause(60);
    emit("in", "agent_message_chunk", chunk(`Reply ${id}. `));
    await words(12);
    await early();
    await words(28);
    for (let index = 0; index < 6; index++) {
      emit("in", "agent_thought_chunk", thought(`Considering the retry path ${index}. `));
      await pause(20);
    }
    toolCall(`${id}-a`, "ls -la");
    await pause(90);
    toolDone(`${id}-a`);
    await words(36);
    toolCall(`${id}-b`, "git status --short");
    await words(4);
    await pause(60);
    toolDone(`${id}-b`);
    for (let index = 0; index < 4; index++) {
      emit("in", "agent_thought_chunk", thought(`Checking the jitter ${index}. `));
      await pause(25);
    }
    await words(30);
    emit("mux", "turn_result", { status: "completed" });
    status = "idle";
    changed();
  }

  /// A turn another agent's message opens, as a coordinator's chat gets them one after another
  /// (Leo, 2026-11-18: "not sure if we've fixed this doubled up looking ass text fixed yet"): the
  /// message's line, a think, then a reply of a few lines, under the last turn's finished reply.
  async function messageTurn(id: string) {
    status = "running";
    const msg = `msg_${id.replace(/\W+/g, "")}`;
    emit("mux", "user_message", {
      text: envelope({ id: msg, thread: msg, sender: "cli", name: `lane-${id}`, body: `Report ${id}: queue clear.` }),
      promptId: `p-${id}`,
    });
    emit("mux", "turn_started", {});
    changed();
    await pause(40);
    for (let index = 0; index < 3; index++) {
      emit("in", "agent_thought_chunk", thought(`Reading the report ${index}. `));
      await pause(20);
    }
    emit("in", "agent_message_chunk", chunk(`Reply to ${id}. `));
    await words(40);
    emit("mux", "turn_result", { status: "completed" });
    status = "idle";
    changed();
  }

  /// A stretch of a coordinator's chat as acpmux wrote it (scrubbed): turns that other agents'
  /// messages, a queue's start and background finishes open, one after another, replayed live at
  /// a stream's pace.
  const coordinator = (
    await Bun.file(
      path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/fixtures/sr2-coord-197051.ndjson"),
    ).text()
  )
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as { dir: string; kind: string; msg: Record<string, unknown> });
  async function replayCoordinator() {
    for (const event of coordinator) {
      if (event.kind === "turn_started") status = "running";
      emit(event.dir, event.kind, event.msg);
      if (event.kind === "turn_result") status = "idle";
      if (event.dir === "mux") changed();
      await pause(event.dir === "mux" ? 50 : 8);
    }
  }

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
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
          if (message.method === "_acpmux/attach") socket = ws;
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Overlap = { t: number; upper: string; lower: string; box: number; ink: number; why?: string };
  type Report = {
    frames: number;
    /// Frames where one row's text draws over the next row's text (what the reader sees).
    overlapFrames: number;
    /// Frames where two rows' boxes cross by more than 1px (a reply's action-row room under a live
    /// line that hugs it crosses at rest by design; reported, not asserted).
    boxFrames: number;
    maxBox: number;
    maxInk: number;
    /// Pairs whose text still crosses once the turn has settled (layout, not motion).
    rest: Overlap[];
    examples: Overlap[];
  };

  /// Samples every painted frame until stopped: adjacent layout boxes plus a sweep of visible ink.
  /// Clipping can reorder ink or hide intervening rows, so box adjacency alone misses collisions.
  const sample = (page: Page) =>
    page.evaluate(() => {
      type Pair = { t: number; upper: string; lower: string; box: number; ink: number; why?: string };
      const w = window as unknown as { __overlaps: Pair[]; __frames: number; __stop: () => void };
      w.__overlaps = [];
      w.__frames = 0;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
      document.body.append(probe);
      let wide = false;
      const label = (row: HTMLElement) =>
        `${row.className.replace(/\s+/g, ".")}:${(row.textContent ?? "").trim().slice(0, 28)}`;
      /// The text's ink: the union of its line boxes, from a range over the row's drawn text (what
      /// the reader sees, transforms included), never the inert copies an animation leaves.
      /// The opacity a node draws at: its own times every ancestor's up to the row's parent.
      const drawnOpacity = (node: HTMLElement, row: HTMLElement) => {
        let opacity = 1;
        for (let at: HTMLElement | null = node; at && at !== row.parentElement; at = at.parentElement)
          opacity *= Number(getComputedStyle(at).opacity);
        return opacity;
      };
      /// The y span inside every ancestor (up to the row) that clips what overflows it.
      const shownSpan = (node: HTMLElement | null, row: HTMLElement) => {
        let top = -Infinity;
        let bottom = Infinity;
        for (let at = node; at && at !== row.parentElement; at = at.parentElement) {
          const style = getComputedStyle(at);
          if (style.overflowY === "visible" && style.overflow === "visible") continue;
          const rect = at.getBoundingClientRect();
          top = Math.max(top, rect.top);
          bottom = Math.min(bottom, rect.bottom);
        }
        return { top, bottom };
      };
      const ink = (row: HTMLElement): { top: number; bottom: number } | undefined => {
        let top = Infinity;
        let bottom = -Infinity;
        const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT);
        const range = document.createRange();
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const parent = node.parentElement;
          // Hidden from readers inside the row is not drawn for the eye; the row itself hidden (a
          // fold's drawn copy, turnFold.ts `ghostOf`) is: its text shows while the fold plays.
          const quiet = parent?.closest("[aria-hidden='true'], [inert]");
          if (!parent || (quiet && quiet !== row && row.contains(quiet))) continue;
          if (getComputedStyle(parent).visibility === "hidden" || drawnOpacity(parent, row) < 0.05) continue;
          // Glyphs, not line boxes: a line box's half-leading above and below draws nothing.
          const lead =
            Math.max(
              0,
              (Number.parseFloat(getComputedStyle(parent).lineHeight) || 0) -
                Number.parseFloat(getComputedStyle(parent).fontSize),
            ) / 2;
          const shown = shownSpan(parent, row);
          range.selectNodeContents(node);
          for (const rect of range.getClientRects()) {
            if (rect.height <= 0 || rect.width <= 0) continue;
            const glyphTop = Math.max(rect.top + lead, shown.top);
            const glyphBottom = Math.min(rect.bottom - lead, shown.bottom);
            if (glyphBottom <= glyphTop) continue;
            top = Math.min(top, glyphTop);
            bottom = Math.max(bottom, glyphBottom);
          }
        }
        // The old words a line's change leaves drawn while they go (Thinking.tsx `cv-roll-out`,
        // the text roll's copy, ui/motion/TextRoll.tsx): inert, but the reader sees them while they show.
        for (const ghost of row.querySelectorAll<HTMLElement>(".cv-roll-out, .ui-text-roll__out")) {
          const style = getComputedStyle(ghost);
          if (style.display === "none" || drawnOpacity(ghost, row) < 0.05) continue;
          const rect = ghost.getBoundingClientRect();
          if (rect.height <= 0) continue;
          // Only what its clipping ancestors let through (the live line clips its roll to its box).
          const shown = shownSpan(ghost.parentElement, row);
          const ghostTop = Math.max(rect.top, shown.top);
          const ghostBottom = Math.min(rect.bottom, shown.bottom);
          if (ghostBottom <= ghostTop) continue;
          top = Math.min(top, ghostTop);
          bottom = Math.max(bottom, ghostBottom);
        }
        if (!Number.isFinite(top)) return undefined;
        // A row clipped while it moves (tailGlide's clip-path) draws only inside its clip.
        const clip = /^inset\(([^)]*)\)/.exec(getComputedStyle(row).clipPath);
        if (clip) {
          const sides = clip[1]!.split(/\s+/).map((side) => Number.parseFloat(side) || 0);
          const [clipTop = 0, , clipBottom = clipTop] = sides;
          const rect = row.getBoundingClientRect();
          top = Math.max(top, rect.top + clipTop);
          bottom = Math.min(bottom, rect.bottom - clipBottom);
          if (bottom <= top) return undefined;
        }
        return { top, bottom };
      };
      const read = (frame: number) => {
        w.__frames += 1;
        const view = scroller.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row")]
          .map((row) => ({ row, rect: row.getBoundingClientRect() }))
          .filter(({ rect }) => rect.height > 0.5 && rect.bottom > view.top && rect.top < view.bottom)
          .sort((a, b) => a.rect.top - b.rect.top)
          .map((entry, index) => ({ ...entry, index, ink: ink(entry.row) }));
        const recorded = new Set<string>();
        const record = (upper: (typeof rows)[number], lower: (typeof rows)[number]) => {
          const key = `${Math.min(upper.index, lower.index)}:${Math.max(upper.index, lower.index)}`;
          if (recorded.has(key)) return;
          recorded.add(key);
          const box = upper.rect.bottom - lower.rect.top;
          const upperInk = upper.ink;
          const lowerInk = lower.ink;
          // A clipped ghost's box may start above the next row while its visible words are below it.
          // Compare the visible intervals, not their ordering by unclipped row boxes.
          const inked =
            upperInk && lowerInk
              ? Math.min(upperInk.bottom, lowerInk.bottom) - Math.max(upperInk.top, lowerInk.top)
              : 0;
          if (box > 1 || inked > 0.5)
            w.__overlaps.push({
              t: Math.round(frame),
              upper: label(upper.row),
              lower: label(lower.row),
              box: Math.round(box * 10) / 10,
              ink: Math.round(inked * 10) / 10,
              // What moved them: each row's running animations (property and progress) and clip.
              why: [upper.row, lower.row]
                .map(
                  (row, pairIndex) =>
                    row
                      .getAnimations()
                      .map((animation) => {
                        const effect = animation.effect as KeyframeEffect | null;
                        const props = effect
                          ?.getKeyframes()
                          .flatMap((frame) =>
                            Object.keys(frame).filter(
                              (key) => !["offset", "easing", "composite", "computedOffset"].includes(key),
                            ),
                          );
                        return `${[...new Set(props)].join("+")}@${Math.round((effect?.getComputedTiming().progress ?? 0) * 100)}`;
                      })
                      .join(",") +
                    `|tr=${getComputedStyle(row).translate}|top=${row.style.top}|clip=${getComputedStyle(row).clipPath}|ink=${JSON.stringify(pairIndex === 0 ? upperInk : lowerInk)}|box=${JSON.stringify(row.getBoundingClientRect())}|layout=${row.offsetTop},${row.offsetHeight}|transform=${getComputedStyle(row).transform}|margin=${getComputedStyle(row).marginTop}|frames=${JSON.stringify(row.getAnimations().map((animation) => (animation.effect as KeyframeEffect).getKeyframes()))}`,
                )
                .join(" ; "),
            });
        };
        for (let index = 0; index + 1 < rows.length; index++) record(rows[index]!, rows[index + 1]!);
        const visible = rows.filter((entry) => entry.ink).sort((a, b) => a.ink!.top - b.ink!.top);
        // The earlier interval with the farthest bottom witnesses every subsequent collision.
        // Sorting plus this linear sweep avoids comparing every pair of mounted rows per frame.
        let farthest: (typeof rows)[number] | undefined;
        for (const current of visible) {
          if (farthest && farthest.ink!.bottom - current.ink!.top > 0.5) record(farthest, current);
          if (!farthest || current.ink!.bottom > farthest.ink!.bottom) farthest = current;
        }
      };
      (w as unknown as { __read: (frame: number) => void }).__read = read;
      const observer = new ResizeObserver(() => read(performance.now()));
      observer.observe(probe);
      const stopFrames = window.cmuxAfterPaint(
        () => {},
        () => {
          wide = !wide;
          probe.style.width = wide ? "2px" : "1px";
        },
      );
      w.__stop = () => {
        stopFrames();
        observer.disconnect();
        probe.remove();
      };
    });
  const stop = (page: Page): Promise<Report> =>
    page.evaluate(() => {
      type Pair = { t: number; upper: string; lower: string; box: number; ink: number; why?: string };
      const w = window as unknown as { __overlaps: Pair[]; __frames: number; __stop: () => void };
      w.__stop();
      // One read at rest: pairs that still cross once everything has settled are layout, not motion.
      (w as unknown as { __read: (frame: number) => void }).__read(-1);
      const rest = w.__overlaps.filter((pair) => pair.t === -1 && pair.ink > 0.5);
      w.__overlaps = w.__overlaps.filter((pair) => pair.t !== -1);
      const inked = w.__overlaps.filter((pair) => pair.ink > 0.5);
      return {
        frames: w.__frames,
        rest,
        overlapFrames: new Set(inked.map((pair) => pair.t)).size,
        boxFrames: new Set(w.__overlaps.filter((pair) => pair.box > 1).map((pair) => pair.t)).size,
        maxBox: Math.max(0, ...w.__overlaps.map((pair) => pair.box)),
        maxInk: Math.max(0, ...inked.map((pair) => pair.ink)),
        // The worst frame of each pair of rows, so one long overlap does not hide another.
        examples: [
          ...inked
            .reduce((worst, pair) => {
              const key = `${pair.upper}|${pair.lower}`;
              if ((worst.get(key)?.ink ?? -1) < pair.ink) worst.set(key, pair);
              return worst;
            }, new Map<string, Pair>())
            .values(),
        ].slice(0, 8),
      };
    });

  for (const [name] of engines)
    test(`${name}: overlap detector respects text clipping and visible band ordering`, async () => {
      const page = await browsers.get(name)!.newPage();
      await installPaintedFrames(page);
      const readFixture = async (rows: string) => {
        await page.setContent(`<style>
          body { margin: 0; }
          .acpmux-scroll { height: 300px; }
          .acpmux-row { position: absolute; left: 0; width: 200px; font: 20px/24px Arial; }
        </style><div class="acpmux-scroll"><div class="acpmux-thread">${rows}</div></div>`);
        await sample(page);
        return stop(page);
      };
      try {
        for (const overflow of ["hidden", "visible"]) {
          const report = await readFixture(`
            <div class="acpmux-row" style="top:0;height:24px">
              <span style="display:block;height:24px;overflow:${overflow}">First line<br>Clipped line</span>
            </div>
            <div class="acpmux-row" style="top:24px;height:24px">Next row</div>`);
          if (overflow === "hidden") expect(report.rest).toEqual([]);
          else expect(report.rest[0]!.ink).toBeGreaterThan(10);
        }
        // The first row's box starts earlier but its clipped words draw below the second row.
        for (const top of [30, 84]) {
          const report = await readFixture(`
            <div class="acpmux-row" style="top:0;height:100px;clip-path:inset(80px 0 0)">
              <span style="display:block;padding-top:80px">Lower words</span>
            </div>
            <div class="acpmux-row" style="top:${top}px;height:24px">Other words</div>`);
          if (top === 30) expect(report.rest).toEqual([]);
          else expect(report.rest[0]!.ink).toBeGreaterThan(10);
        }
        // Box ordering can put unrelated or completely clipped ink between two colliding rows.
        for (const middle of ["", "clip-path:inset(30px 0 0)"]) {
          const report = await readFixture(`
            <div class="acpmux-row" style="top:0;height:100px;clip-path:inset(80px 0 0)">
              <span style="display:block;padding-top:80px">Lower words</span>
            </div>
            <div class="acpmux-row" style="top:30px;height:24px;${middle}">Middle words</div>
            <div class="acpmux-row" style="top:84px;height:24px">Other words</div>`);
          expect(
            report.rest.some(
              (pair) => pair.ink > 10 && pair.upper.includes("Lower words") && pair.lower.includes("Other words"),
            ),
          ).toBe(true);
        }
      } finally {
        await page.close();
      }
    });

  /// A busy main thread, as a loaded Mac's is: a long task of `busy` ms every `every` ms.
  const lag = (page: Page, busy: number, every: number) =>
    page.evaluate(
      ([busy, every]) => {
        const w = window as unknown as { __lag?: number };
        w.__lag = window.setInterval(() => {
          const until = performance.now() + busy;
          while (performance.now() < until) {
            /* busy */
          }
        }, every);
      },
      [busy, every] as const,
    );

  async function open(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Opening paragraph 13.").waitFor();
    // fixed-wait: the opened chat settles (its fades end) before the frames under test.
    await page.waitForTimeout(600);
    return page;
  }

  const cases: { name: string; busy: number; every: number; scrolledUp: boolean }[] = [
    { name: "followed, no lag", busy: 0, every: 0, scrolledUp: false },
    { name: "followed, lagging", busy: 45, every: 60, scrolledUp: false },
    { name: "scrolled up, lagging", busy: 45, every: 60, scrolledUp: true },
  ];
  for (const [name] of engines)
    for (const scenario of cases)
      test(`${name}: ${scenario.name}: no row draws over the next while the reply streams`, async () => {
        const page = await open(name);
        if (name === "chromium" && scenario.busy > 0) {
          const cdp = await page.context().newCDPSession(page);
          await cdp.send("Emulation.setCPUThrottlingRate", { rate: 3 });
        }
        if (scenario.busy > 0) await lag(page, scenario.busy, scenario.every);
        await sample(page);
        const id = `${name}-${scenario.name.replace(/\W+/g, "-")}`;
        // Scrolled up: once the reply has a few lines, the reader scrolls up a little (past the
        // follow deadband), so the view no longer follows while the reply grows in sight.
        await turn(id, async () => {
          if (!scenario.scrolledUp) return;
          await page.mouse.move(450, 300);
          await page.mouse.wheel(0, -60);
        });
        await page.locator(".acpmux-row--last-footer").waitFor({ timeout: 60_000 });
        // fixed-wait: the reply's last lines drain and its rows come to rest.
        await page.waitForTimeout(800);
        // At rest no row keeps a clip: a tail glide's clip held under the reader's scroll and left on
        // once the turn's fold ended hid the reply's last lines over nothing (review of cmux#41034).
        const heldClips = await page.evaluate(
          () =>
            document
              .getAnimations()
              .filter(
                (animation) =>
                  animation.playState !== "finished" &&
                  animation.playState !== "idle" &&
                  animation.effect instanceof KeyframeEffect &&
                  animation.effect.getKeyframes().some((frame) => "clipPath" in frame),
              ).length,
        );
        const report = await stop(page);
        console.log(`OVERLAP_REPORT ${JSON.stringify({ engine: name, scenario: scenario.name, ...report })}`);
        await page.close();
        expect(report.frames).toBeGreaterThan(20);
        expect({ overlapFrames: report.overlapFrames, examples: report.examples, heldClips }).toEqual({
          overlapFrames: 0,
          examples: [],
          heldClips: 0,
        });
      });

  // Another agent's message under a finished reply, then the reply to it streaming: the new turn's
  // rows must land below the reply above, never over it (Leo's coordinator chat, 2026-11-18: the
  // new reply drew over the last lines of the one before, then settled stacked).
  const messageCases: { name: string; busy: number; every: number }[] = [
    { name: "no lag", busy: 0, every: 0 },
    { name: "lagging", busy: 45, every: 60 },
  ];
  for (const [name] of engines)
    for (const scenario of messageCases)
      test(`${name}: agent messages one after another, ${scenario.name}: each turn lands under the reply above`, async () => {
        const page = await open(name);
        if (scenario.busy > 0) await lag(page, scenario.busy, scenario.every);
        await sample(page);
        const id = `${name}-msg-${scenario.name.replace(/\W+/g, "-")}`;
        for (let index = 0; index < 3; index++) await messageTurn(`${id}-${index}`);
        await replayCoordinator();
        // fixed-wait: the last reply's lines drain and its rows come to rest.
        await page.waitForTimeout(800);
        const report = await stop(page);
        console.log(
          `OVERLAP_REPORT ${JSON.stringify({ engine: name, scenario: `messages ${scenario.name}`, ...report })}`,
        );
        await page.close();
        expect(report.frames).toBeGreaterThan(20);
        expect({ overlapFrames: report.overlapFrames, examples: report.examples }).toEqual({
          overlapFrames: 0,
          examples: [],
        });
      });
});
