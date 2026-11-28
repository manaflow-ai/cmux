// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// No two transcript rows ever draw over each other while a reply streams, under lag too (Leo,
// 2026-11-11: "when the text comes in. esp when it's lagging, there's a breif moment where ther'es
// overlapping text between the sent out text (from you) and the subequent tool calls/thinking").
// A reply streams text, thinks, calls a tool, streams more and thinks again, while the page's main
// thread is kept busy (a long task every few frames, as a loaded Mac's WebKit sees), in a chat that
// follows its latest line and in one the reader scrolled up a little. For every rendering frame,
// snapshot final observer-phase geometry (renderedFrames.ts): the ink of each row's text (and of the old words a
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
import { installRenderedFrames } from "./support/renderedFrames";
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
  type Event = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: Record<string, unknown>;
  };
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
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
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
  const endMarker = (id: string) => `Overlap reply end ${id}.`;

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
    emit("in", "agent_message_chunk", chunk(`\n\n${endMarker(id)}`));
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
      text: envelope({
        id: msg,
        thread: msg,
        sender: "cli",
        name: `lane-${id}`,
        body: `Report ${id}: queue clear.`,
      }),
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
    emit("in", "agent_message_chunk", chunk(`\n\n${endMarker(id)}`));
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

  type Overlap = {
    t: number;
    frame?: number;
    upper: string;
    lower: string;
    box: number;
    ink: number;
    why?: string;
  };
  type Report = {
    frames: number;
    drivenFrames: number;
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
    observer?: {
      frames: number;
      overlapFrames: number;
      maxInk: number;
      examples: Overlap[];
      sharedObserverFrames: number;
      observerOnlyFrames: number;
      unpairedObserverFrames: number;
    };
  };

  /// Snapshots final rendering geometry; optional observer diagnostics expose earlier transient states.
  /// Clipping can reorder ink or hide intervening rows, so box adjacency alone misses collisions.
  const sample = (page: Page, diagnoseObserver = false) =>
    page.evaluate((diagnoseObserver) => {
      type Pair = {
        t: number;
        frame?: number;
        upper: string;
        lower: string;
        box: number;
        ink: number;
        why?: string;
      };
      const w = window as unknown as {
        __overlaps: Pair[];
        __frames: number;
        __paintedOverlaps: Pair[];
        __paintedFrames: Set<number>;
        __drivenFrames: number;
        __observerEnabled: boolean;
        __stop: () => void;
      };
      w.__overlaps = [];
      w.__frames = 0;
      w.__paintedOverlaps = [];
      w.__paintedFrames = new Set();
      w.__drivenFrames = 0;
      w.__observerEnabled = diagnoseObserver;
      let drivenFrame = -1;
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
      const read = (frame: number, capture = false) => {
        const frameId = Math.round(capture ? frame : drivenFrame);
        if (!capture) w.__frames += 1;
        const overlaps: Pair[] = capture ? [] : w.__overlaps;
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
            overlaps.push({
              t: Math.round(frame),
              frame: frameId,
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
        return overlaps;
      };
      (w as unknown as { __read: (frame: number) => void }).__read = read;
      const observer = diagnoseObserver ? new ResizeObserver(() => read(performance.now())) : undefined;
      observer?.observe(probe);
      const stopFrames = window.cmuxFrameSnapshots(
        (frame) => read(frame, true),
        (pairs, frame) => {
          w.__paintedFrames.add(Math.round(frame));
          w.__paintedOverlaps.push(...pairs);
        },
        (frame) => {
          drivenFrame = frame;
          w.__drivenFrames += 1;
          if (diagnoseObserver) {
            wide = !wide;
            probe.style.width = wide ? "2px" : "1px";
          }
        },
      );
      w.__stop = () => {
        stopFrames();
        observer?.disconnect();
        probe.remove();
      };
    }, diagnoseObserver);
  const stop = async (page: Page): Promise<Report> => {
    const report = await page.evaluate(() => {
      type Pair = {
        t: number;
        frame?: number;
        upper: string;
        lower: string;
        box: number;
        ink: number;
        why?: string;
      };
      const w = window as unknown as {
        __overlaps: Pair[];
        __frames: number;
        __paintedOverlaps: Pair[];
        __paintedFrames: Set<number>;
        __drivenFrames: number;
        __observerEnabled: boolean;
        __stop: () => void;
      };
      w.__stop();
      // One read at rest: pairs that still cross once everything has settled are layout, not motion.
      (w as unknown as { __read: (frame: number) => void }).__read(-1);
      const rest = w.__overlaps.filter((pair) => pair.t === -1 && pair.ink > 0.5);
      w.__overlaps = w.__overlaps.filter((pair) => pair.t !== -1);
      const inked = w.__overlaps.filter((pair) => pair.ink > 0.5);
      const paintedInk = w.__paintedOverlaps.filter((pair) => pair.ink > 0.5);
      const paintedFrames = new Set(paintedInk.map((pair) => pair.frame));
      const observerFrames = new Set(inked.map((pair) => pair.frame!));
      return {
        observer: w.__observerEnabled
          ? {
              frames: w.__frames,
              overlapFrames: observerFrames.size,
              maxInk: Math.max(0, ...inked.map((pair) => pair.ink)),
              examples: inked.slice(0, 8),
              sharedObserverFrames: [...observerFrames].filter((frame) => paintedFrames.has(frame)).length,
              observerOnlyFrames: [...observerFrames].filter(
                (frame) => w.__paintedFrames.has(frame) && !paintedFrames.has(frame),
              ).length,
              unpairedObserverFrames: [...observerFrames].filter((frame) => !w.__paintedFrames.has(frame)).length,
            }
          : undefined,
        frames: w.__paintedFrames.size,
        drivenFrames: w.__drivenFrames,
        rest,
        overlapFrames: paintedFrames.size,
        boxFrames: new Set(w.__paintedOverlaps.filter((pair) => pair.box > 1).map((pair) => pair.t)).size,
        maxBox: Math.max(0, ...w.__paintedOverlaps.map((pair) => pair.box)),
        maxInk: Math.max(0, ...paintedInk.map((pair) => pair.ink)),
        // The worst frame of each pair of rows, so one long overlap does not hide another.
        examples: [
          ...paintedInk
            .reduce((worst, pair) => {
              const key = `${pair.upper}|${pair.lower}`;
              if ((worst.get(key)?.ink ?? -1) < pair.ink) worst.set(key, pair);
              return worst;
            }, new Map<string, Pair>())
            .values(),
        ].slice(0, 8),
      };
    });
    expect(report.frames, "the sampler must read painted frames").toBeGreaterThan(0);
    // Callback coverage alone does not prove distinct geometry: the one-frame control below
    // also checks that a collision repaired on the next frame is observed.
    expect(report.frames, "painted read callbacks must cover driven frames").toBeGreaterThanOrEqual(
      report.drivenFrames - 2,
    );
    return report;
  };

  for (const [name] of engines)
    test(`${name}: overlap detector distinguishes observer transients from painted collisions`, async () => {
      const page = await browsers.get(name)!.newPage();
      await installPaintedFrames(page);
      await installRenderedFrames(page);
      try {
        for (const heal of [true, false]) {
          await page.setContent(`<style>
            body { margin: 0; }
            .acpmux-scroll { height: 300px; }
            .acpmux-row { position: absolute; left: 0; width: 200px; height: 24px; font: 20px/24px Arial; }
          </style><div class="acpmux-scroll"><div class="acpmux-thread">
            <div class="acpmux-row" style="top:0">First words</div>
            <div class="acpmux-row" id="lower" style="top:24px">Next words</div>
          </div></div><div id="repair-probe" style="width:1px;height:1px"></div>`);
          await sample(page, true);
          await page.evaluate(async (heal) => {
            const lower = document.getElementById("lower")!;
            const probe = document.getElementById("repair-probe")!;
            let armed = false;
            // Constructed after the sampler: its callback sees the transient overlap first,
            // then this observer repairs the geometry before the same frame paints.
            const repair = new ResizeObserver(() => {
              if (armed && heal) lower.style.top = "24px";
            });
            repair.observe(probe);
            await window.cmuxPaintFrame(() => {
              armed = true;
              lower.style.top = "0px";
              probe.style.width = "2px";
            });
            await window.cmuxPaintFrame();
            repair.disconnect();
          }, heal);
          const report = await stop(page);
          console.log(`OVERLAP_PHASE_CONTROL ${JSON.stringify({ engine: name, heal, report })}`);
          expect(report.observer!.overlapFrames).toBeGreaterThan(0);
          expect(report.frames).toBeGreaterThan(0);
          if (heal) {
            expect(report.observer!.observerOnlyFrames).toBeGreaterThan(0);
            expect(report.overlapFrames).toBe(0);
          } else {
            expect(report.overlapFrames).toBeGreaterThan(0);
            expect(report.maxInk).toBeGreaterThan(10);
          }
        }
      } finally {
        await page.close();
      }
    });

  for (const [name] of engines)
    test(`${name}: overlap detector catches one painted collision repaired on the next frame`, async () => {
      const page = await browsers.get(name)!.newPage();
      await installPaintedFrames(page);
      await installRenderedFrames(page);
      try {
        for (const busy of [0, 45]) {
          await page.setContent(`<style>
            body { margin: 0; }
            .acpmux-scroll { height: 300px; }
            .acpmux-row { position: absolute; left: 0; width: 200px; height: 24px; font: 20px/24px Arial; }
          </style><div class="acpmux-scroll"><div class="acpmux-thread">
            <div class="acpmux-row" style="top:0">First words</div>
            <div class="acpmux-row" id="lower" style="top:24px">Next words</div>
          </div></div>`);
          await sample(page);
          await page.evaluate(async (busy) => {
            const lower = document.getElementById("lower")!;
            await window.cmuxPaintFrame(() => {
              lower.style.top = "0px";
              requestAnimationFrame(() => {
                lower.style.top = "24px";
              });
              const until = performance.now() + busy;
              while (performance.now() < until) {
                /* A loaded frame still must be sampled before the following frame repairs it. */
              }
            });
            await window.cmuxPaintFrame();
          }, busy);
          const report = await stop(page);
          console.log(`OVERLAP_ONE_FRAME_CONTROL ${JSON.stringify({ engine: name, busy, report })}`);
          expect(report.overlapFrames).toBeGreaterThan(0);
          expect(report.maxInk).toBeGreaterThan(10);
          expect(report.rest).toEqual([]);
        }
      } finally {
        await page.close();
      }
    });

  for (const [name] of engines)
    test(`${name}: overlap detector respects text clipping and visible band ordering`, async () => {
      const page = await browsers.get(name)!.newPage();
      await installPaintedFrames(page);
      await installRenderedFrames(page);
      const readFixture = async (rows: string) => {
        await page.setContent(`<style>
          body { margin: 0; }
          .acpmux-scroll { height: 300px; }
          .acpmux-row { position: absolute; left: 0; width: 200px; font: 20px/24px Arial; }
        </style><div class="acpmux-scroll"><div class="acpmux-thread">${rows}</div></div>`);
        await sample(page);
        await page.evaluate(() => window.cmuxPaintFrame());
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
    await installRenderedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Opening paragraph 13.").waitFor();
    // fixed-wait: the opened chat settles (its fades end) before the frames under test.
    await page.waitForTimeout(600);
    return page;
  }

  // Read mounted prose before any scrolling: scrolling itself settles folds and tail glides.
  // A second check may mount a virtualized final reply, but cannot repair the first check's result.
  async function assertReplyReleased(page: Page, id: string, scrolledUp = false) {
    const prose = page.locator(".acpmux-row:not(.acpmux-row--fold-ghost) .cv-reply");
    const finalReply = prose.filter({ hasText: endMarker(id) });
    if (!scrolledUp) expect(await finalReply.count(), "followed reply must be mounted without scrolling").toBe(1);
    const inspect = async () => {
      const hidden = await prose.evaluateAll((replies, marker) => {
        const problems: string[] = [];
        const scroller = document.querySelector(".acpmux-scroll")!.getBoundingClientRect();
        for (const reply of replies) {
          const owner = reply.closest<HTMLElement>(".acpmux-row")!;
          const bounds = owner.getBoundingClientRect();
          // Do not force layout of browser-skipped overscan. Skip only the explicit offscreen
          // content-visibility:auto state, never an ordinary hidden/clipped reply in the viewport.
          if (
            owner.classList.contains("acpmux-row--offscreen") &&
            getComputedStyle(owner).contentVisibility === "auto" &&
            (bounds.bottom <= scroller.top || bounds.top >= scroller.bottom) &&
            !reply.checkVisibility({ contentVisibilityAuto: true })
          ) {
            if (reply.textContent?.includes(marker)) problems.push("final reply is still browser-skipped");
            continue;
          }
          const row = reply.closest<HTMLElement>(".acpmux-row")!;
          const range = document.createRange();
          const walker = document.createTreeWalker(reply, NodeFilter.SHOW_TEXT);
          let words = 0;
          for (let text = walker.nextNode(); text; text = walker.nextNode()) {
            if (!text.textContent?.trim()) continue;
            words++;
            range.selectNodeContents(text);
            const rects = [...range.getClientRects()].filter((rect) => rect.width > 0 && rect.height > 0);
            if (!rects.length) problems.push("text has no drawn bounds");
            for (let node = text.parentElement; node && node !== row.parentElement; node = node.parentElement) {
              const style = getComputedStyle(node);
              if (Number(style.opacity) < 0.99 || style.visibility !== "visible" || style.display === "none")
                problems.push("prose remains hidden or faded");
              const box = node.getBoundingClientRect();
              let top = -Infinity;
              let bottom = Infinity;
              if (style.overflowY !== "visible") {
                top = box.top;
                bottom = box.bottom;
              }
              const clip = /^inset\(([^)]*)\)/.exec(style.clipPath);
              if (clip) {
                const sides = clip[1]!.split(/\s+/).map((side) => Number.parseFloat(side) || 0);
                top = Math.max(top, box.top + (sides[0] ?? 0));
                bottom = Math.min(bottom, box.bottom - (sides[2] ?? sides[0] ?? 0));
              } else if (style.clipPath !== "none") problems.push(`unexpected prose clip: ${style.clipPath}`);
              // A Range can include half-leading; allow that empty space but never a clipped text line.
              const parentStyle = getComputedStyle(text.parentElement!);
              const lead =
                Math.max(
                  0,
                  (Number.parseFloat(parentStyle.lineHeight) || 0) - Number.parseFloat(parentStyle.fontSize),
                ) / 2;
              if (rects.some((rect) => rect.top + lead < top - 1 || rect.bottom - lead > bottom + 1))
                problems.push("prose remains clipped");
            }
          }
          if (!words) problems.push("reply has no text");
        }
        return [...new Set(problems)];
      }, endMarker(id));
      expect(hidden, `mounted replies before/after mounting ${id} must remain readable`).toEqual([]);
    };
    // Allow finite entrance effects to finish without changing scroll position or layout styles.
    await page.waitForFunction(
      () =>
        [...document.querySelectorAll(".acpmux-row:not(.acpmux-row--fold-ghost):has(.cv-reply)")].every((row) =>
          row
            .getAnimations({ subtree: true })
            .every(
              (animation) =>
                animation.playState !== "running" || animation.effect?.getComputedTiming().iterations === Infinity,
            ),
        ),
      undefined,
      { timeout: 10_000 },
    );
    await inspect();
    if ((await finalReply.count()) === 0) {
      expect(scrolledUp, "only the scrolled-up case may mount its final reply").toBe(true);
      await page.locator(".acpmux-scroll").evaluate((node) => {
        node.scrollTop = node.scrollHeight;
      });
      await finalReply.waitFor({ state: "attached", timeout: 10_000 });
      await page.waitForFunction(
        (marker) => {
          const reply = [...document.querySelectorAll(".cv-reply")].find((node) => node.textContent?.includes(marker));
          return reply
            ?.closest(".acpmux-row")
            ?.getAnimations({ subtree: true })
            .every((animation) => animation.playState !== "running");
        },
        endMarker(id),
        { timeout: 10_000 },
      );
    }
    expect(await finalReply.count(), "the completed reply must contain its end marker").toBe(1);
    await inspect();
  }

  for (const [name] of engines)
    test(`${name}: settled content check catches clipping before a scroll can clear it`, async () => {
      const page = await browsers.get(name)!.newPage();
      try {
        await page.setContent(`<div class="acpmux-scroll" style="height:100px;overflow:auto">
          <div class="acpmux-row" style="clip-path:inset(0 0 24px);height:72px;font:20px/24px Arial">
            <div class="cv-reply">First line<br>Second line<br>${endMarker("scroll-control")}</div>
          </div><div style="height:500px"></div></div>`);
        await page.evaluate(() => {
          document.querySelector(".acpmux-scroll")!.addEventListener("scroll", () => {
            (document.querySelector(".acpmux-row") as HTMLElement).style.clipPath = "none";
          });
        });
        await expect(assertReplyReleased(page, "scroll-control")).rejects.toThrow("prose remains clipped");
        expect(await page.locator(".acpmux-scroll").evaluate((node) => node.scrollTop)).toBe(0);
        await page.locator(".acpmux-scroll").evaluate((node) => {
          node.scrollTop = 1;
          node.dispatchEvent(new Event("scroll"));
        });
        await assertReplyReleased(page, "scroll-control");
      } finally {
        await page.close();
      }
    });

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
        await page.locator(".acpmux-row--final-footer").waitFor({ timeout: 60_000 });
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
        await assertReplyReleased(page, id, scenario.scrolledUp);
        await page.close();
        expect(report.frames).toBeGreaterThan(20);
        expect({
          overlapFrames: report.overlapFrames,
          examples: report.examples,
          rest: report.rest,
          heldClips,
        }).toEqual({
          overlapFrames: 0,
          examples: [],
          rest: [],
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
        // Finish with a known reply, so the recorded history cannot hide missing final content.
        const finalId = `${id}-final`;
        await messageTurn(finalId);
        await page.locator(".acpmux-row--final-footer").waitFor({ timeout: 60_000 });
        // fixed-wait: the last reply's lines drain and its rows come to rest.
        await page.waitForTimeout(800);
        const report = await stop(page);
        console.log(
          `OVERLAP_REPORT ${JSON.stringify({ engine: name, scenario: `messages ${scenario.name}`, ...report })}`,
        );
        await assertReplyReleased(page, finalId);
        await page.close();
        expect(report.frames).toBeGreaterThan(20);
        expect({ overlapFrames: report.overlapFrames, examples: report.examples, rest: report.rest }).toEqual({
          overlapFrames: 0,
          examples: [],
          rest: [],
        });
      });
});
