// cmux-web-test-timeout: 200
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A followed chat stays still at its bottom while a reply streams (Leo, 2026-10-20: "the transcript
// jumps up and down instead of staying pinned"). The reply streams a few words at a time, a tool call
// opens the turn's working line over the reply, a queued prompt's card comes into the bottom stack
// and goes, and a queued prompt is sent as the next turn. On every painted frame the text the reader
// is reading only moves up, and the view rests at the latest line. Sampled per frame on base
// 6fe9ab414ee: the reply dropped 35px and slid back when the tool call came (a glide, since removed,
// moved the whole thread by what grew, also above the reply), and the view dropped 54px when the
// queue card left the stack, then rose again as its prompt arrived. Growth now moves the view in the
// frame that draws it (#23807), so nothing waits on a glide.
// A turn that ends leaves its reply and composer still: its footer takes the running line's place at
// the same height, and a live activity line under a plan reserves that footer slot too. The turn is
// read once its reply has been drawn to its end (`rest`); the end-of-turn frame strip asserts no edge
// moves for short, long, or tool-ending replies.
// A queued prompt deleted from the queue never comes in as a row: the view goes back to its end at
// once, with no card-high gap held under the last row (held for a second after #22858).
// A chat whose history is rich (headings, code blocks, tables, lists, each laid out at its own height
// as it mounts) opens at its latest line and holds it on every painted frame.
// A reader who scrolls up while it streams is left where they scrolled: in WebKit the wheel moves the
// offset a frame before its scroll event, and a snapshot landing between them put the view back at
// the latest row (on base, 3 runs in 6).
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon. Both engines the app uses (WebKit draws the pane in cmux NEXT); one not installed skips.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-stream-jitter.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-stream-jitter: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("stream jitter", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000c1";
  let status = "idle";
  let queue: { promptId: string; prompt: string }[] = [];
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Backoff",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: queue.length,
    queue,
    turnCount: 1,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
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
  for (let index = 0; index < 20; index++)
    record(
      "in",
      "agent_message_chunk",
      chunk(`Opening paragraph ${index}. Words that fill the view with history.\n\n`),
    );
  record("mux", "turn_result", { status: "completed" });
  const opened = events.length;
  // A second chat, finished, whose one reply is a write-up in rich markdown.
  const RICH = "0190a000-0000-7000-8000-0000000000c2";
  type Record3 = [dir: string, kind: string, msg: Record<string, unknown>];
  const richSteps: Record3[] = [
    ["mux", "user_message", { text: "Write up the retry policy", promptId: "r-0" }],
    ["mux", "turn_started", {}],
    ...Array.from({ length: 12 }, (_, index): Record3 => [
      "in",
      "agent_message_chunk",
      chunk(
        `## Part ${index + 1}\n\nEach retry waits longer than the last and adds jitter.\n\n` +
          `\`\`\`ts\nconst delay${index} = base * 2 ** attempt + jitter();\nawait sleep(delay${index});\n\`\`\`\n\n` +
          "| attempt | delay |\n| --- | --- |\n| 1 | 200 ms |\n| 2 | 400 ms |\n\n- waits longer\n- adds jitter\n\n",
      ),
    ]),
    ["in", "agent_message_chunk", chunk("Rich ending marker.")],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const rich = richSteps.map(([dir, kind, msg], index) => ({
    sessionId: RICH,
    seq: index + 1,
    at: Date.now(),
    dir,
    kind,
    msg,
  }));
  const richSummary = () => ({
    ...summary(),
    sessionId: RICH,
    title: "Retry write-up",
    status: "idle",
    queued: 0,
    queue: [],
  });

  function answer(method: string, params: { sessionId?: string }): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary(), richSummary()] };
      case "_acpmux/attach":
        if (params.sessionId === RICH) return { session: richSummary(), lastSeq: rich.length, events: rich };
        return { session: summary(), lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        if (params.sessionId === RICH) return { events: [], hasMore: false, lastSeq: rich.length };
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let socket: { send(data: string): void } | undefined;
  const emit = (dir: string, kind: string, msg: Record<string, unknown>) =>
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(dir, kind, msg) }));
  /// acpmux's session_changed, which carries the status and the queue.
  const changed = () =>
    socket?.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, session: summary(), kind: "queue", seq: events.length },
      }),
    );
  const enqueue = (promptId: string, text: string) => {
    emit("mux", "queued", { text, promptId, position: 1 });
    queue = [{ promptId, prompt: text }];
    changed();
  };
  const unqueue = (kind: "queue_removed" | "dequeued", promptId: string) => {
    emit("mux", kind, { promptId });
    queue = [];
    changed();
  };

  const WORDS =
    "the client waits a little longer before each retry and adds random jitter so a crowd does not retry in step".split(
      " ",
    );
  /// A turn streamed a few words at a time; `at(index)` adds what comes in after chunk `index`.
  async function stream(promptId: string, prompt: string, marker: string, chunks: number, at = (_: number) => {}) {
    status = "running";
    emit("mux", "user_message", { text: prompt, promptId });
    emit("mux", "turn_started", {});
    changed();
    emit("in", "agent_message_chunk", chunk(`${marker}. `));
    for (let index = 0; index < chunks; index++) {
      const words = WORDS.slice(index % 7, (index % 7) + 3).join(" ");
      emit("in", "agent_message_chunk", chunk(`${words}${index % 25 === 24 ? ".\n\n" : " "}`));
      at(index);
      // fixed-wait: the stream's own cadence, a chunk every frame or two as an agent sends them, is the input under test.
      await Bun.sleep(16 + (index % 3) * 10);
    }
  }
  const endTurn = () => {
    emit("mux", "turn_result", { status: "completed" });
    status = "idle";
    changed();
  };
  const toolCall = (id: string) =>
    emit(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: "ls -la",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "ls -la" },
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
          // The streamed turns go to the page that has the streaming chat open.
          if (message.method === "_acpmux/attach" && message.params?.sessionId !== RICH) socket = ws;
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
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function open(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Opening paragraph 19.").waitFor();
    await rest(page);
    return page;
  }

  /// Resolves once the view is at rest: the transcript's offset has held, with nothing in it
  /// animating, for 6 painted frames. A streamed reply is drawn over frames after its last chunk
  /// (StreamReveal), each step fading in (`.cv-fresh`): while one fades, the reply can still grow a
  /// line. The offset alone holds for 6 frames between two wrapped lines, and a reply that grew a
  /// line then moved the view up 23px in the frames read after it (#23807's first CI run).
  /// Infinite animations (a spinner, the running line's shimmer) never end and do not count.
  const rest = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const moving = () =>
        scroller
          .getAnimations({ subtree: true })
          .some(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      let last = NaN;
      for (let held = 0, frames = 0; held < 6 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const still = scroller.scrollTop === last && !moving();
        held = still ? held + 1 : 0;
        last = scroller.scrollTop;
      }
    });

  /// Resolves once the turn whose reply holds `marker` has ended: its footer is the chat's last row,
  /// after the reply (when the reply has scrolled out of the drawn range, after it all the same).
  const ended = (page: Page, marker: string) =>
    page.waitForFunction((marker) => {
      const at = (row: Element) => Number(row.getAttribute("aria-posinset"));
      const footer = document.querySelector(".acpmux-row--last-footer");
      const reply = [...document.querySelectorAll(".acpmux-scroll .acpmux-row")].find((row) =>
        row.textContent?.includes(marker),
      );
      return !!footer && (!reply || at(footer) > at(reply));
    }, marker);

  /// One frame: where the row holding `marker` is drawn (its `top` position included).
  type Frame = {
    t: number;
    marker?: number;
    messageBottom?: number;
    composerTop?: number;
    settled?: boolean;
    /// What is laid out under the reply's text (its meta line, a trailing tool row, the live line
    /// or the footer): from the text's end to the last row's layout end (its entrance motion aside).
    under?: number;
  };
  /// Samples every painted frame until `stop`, as the frame paints it: in a ResizeObserver made after
  /// the pane's, on a probe resized in each frame's callbacks, so the read runs after the frame's
  /// layout and the pane's own observer (which places a row that grew before paint), right before
  /// the paint. A read in a task after the frame (cmuxAfterPaint) can come after a task already
  /// queued has grown the streaming reply: a state no frame painted, a line taller than the rows
  /// under it were placed for (23 px, on the CI runner's busy main thread).
  const sample = (page: Page, marker: string) =>
    page.evaluate((marker) => {
      const w = window as unknown as { __frames: Frame[]; __stop: () => void };
      w.__frames = [];
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
      document.body.append(probe);
      let wide = false;
      const read = (frame: number) => {
        const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((each) =>
          each.textContent?.includes(marker),
        );
        const message = row?.querySelector<HTMLElement>(".cv-md");
        const composer = document.querySelector<HTMLElement>(".acpmux-dock");
        w.__frames.push({
          t: Math.round(frame),
          marker: row?.getBoundingClientRect().top,
          messageBottom: message?.getBoundingClientRect().bottom,
          composerTop: composer?.getBoundingClientRect().top,
          settled: Boolean(document.querySelector(".acpmux-row--last-footer")),
          under: (() => {
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
            const last = rows.reduce<HTMLElement | undefined>(
              (low, each) =>
                !low || each.getBoundingClientRect().bottom > low.getBoundingClientRect().bottom ? each : low,
              undefined,
            );
            return message && last
              ? last.offsetTop +
                  last.offsetHeight -
                  (message.getBoundingClientRect().bottom - scroller.getBoundingClientRect().top + scroller.scrollTop)
              : undefined;
          })(),
        });
      };
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
    }, marker);
  const stop = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: Frame[]; __stop: () => void };
      w.__stop();
      return w.__frames;
    });
  /// Resolves after `count` painted frames.
  const painted = (page: Page, count: number) =>
    page.evaluate(async (count) => {
      for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
    }, count);
  /// Frames where the marked text moved down (it only ever moves up while followed).
  const drops = (frames: Frame[]) =>
    frames.flatMap((frame, index) => {
      const before = frames[index - 1]?.marker;
      return before !== undefined && frame.marker !== undefined && frame.marker - before > 1
        ? [`${frame.t}ms: ${before.toFixed(1)} -> ${frame.marker.toFixed(1)}`]
        : [];
    });
  /// How far the view rests from its end (the follow deadband is 4px).
  const fromEnd = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop);
    });
  const scrollTop = (page: Page) =>
    page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop);
  /// Where the view comes to rest: Linux WebKit animates a wheel step over several frames,
  /// so a read at a fixed delay can land mid-glide. Resolves once scrollTop holds for 200ms.
  const settledScrollTop = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<number>((resolve) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          let last = scroller.scrollTop;
          let since = performance.now();
          window.cmuxAfterPaint((now) => {
            if (scroller.scrollTop !== last) [last, since] = [scroller.scrollTop, now];
            if (now - since < 200) return;
            resolve(last);
            return false;
          });
        }),
    );

  test.each(engines.map(([name]) => name))(
    "%s: a chat with rich history opens at its latest line and holds it",
    async (name) => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
      await installPaintedFrames(page);
      // From the first painted frame that shows the latest line: where it sits against the view's
      // foot, and how far the view rests from its end.
      await page.addInitScript(() => {
        const frames: { t: number; line: number; fromEnd: number }[] = [];
        (window as unknown as { __opened: typeof frames }).__opened = frames;
        window.cmuxAfterPaint((frame) => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
          if (!scroller || scroller.hasAttribute("data-seeking")) return;
          const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((each) =>
            each.textContent?.includes("Rich ending marker."),
          );
          if (!row) return;
          frames.push({
            t: Math.round(frame),
            line: scroller.getBoundingClientRect().bottom - row.getBoundingClientRect().bottom,
            fromEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
          });
        });
      });
      const { port } = vite!.httpServer!.address() as { port: number };
      const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${RICH}`);
      await page.getByText("Rich ending marker.").waitFor();
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
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: the reply only moves up as a tool call, the working line and the queue card come and go",
    async (name) => {
      const page = await open(name);
      const turn = events.length;
      const marker = `Stream marker ${turn}`;
      await sample(page, marker);
      await stream(`p-${turn}`, `Stream turn ${turn}`, marker, 160, (index) => {
        if (index === 50) toolCall(`t-${turn}`);
        if (index === 55) toolDone(`t-${turn}`);
        if (index === 80) enqueue(`q-${turn}`, "and then also do the other thing please");
        if (index === 120) unqueue("queue_removed", `q-${turn}`);
      });
      endTurn();
      await ended(page, marker);
      await rest(page);
      const frames = await stop(page);
      expect({ drops: drops(frames), atEnd: (await fromEnd(page)) <= 4 }).toEqual({ drops: [], atEnd: true });
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))("%s: a turn that ends leaves its reply where it was", async (name) => {
    const page = await open(name);
    const turn = events.length;
    const marker = `End marker ${turn}`;
    await stream(`p-${turn}`, `End turn ${turn}`, marker, 20);
    await rest(page);
    await sample(page, marker);
    await rest(page);
    // The footer takes the running line's place at its height, and the reply over them keeps its
    // gap: the turn's end moves nothing (it slid the reply 4px down, the gap a reply leaves over
    // a footer being the meta gap and over the running line the message gap).
    endTurn();
    await page.locator(".acpmux-row--last-footer").waitFor();
    await rest(page);
    const frames = (await stop(page)).flatMap((frame) => (frame.marker === undefined ? [] : [frame.marker]));
    expect(frames.length).toBeGreaterThanOrEqual(5);
    expect(Math.max(...frames) - Math.min(...frames)).toBeLessThanOrEqual(0.5);
    expect(await fromEnd(page)).toBeLessThanOrEqual(4);
    await page.close();
  });

  test.each(engines.map(([name]) => name))(
    "%s: settling short and long replies moves nothing; a tool-ending one folds its tool above the reply once",
    async (name) => {
      const page = await open(name);
      for (const scenario of [
        { label: "short", chunks: 1, toolEnding: false },
        { label: "long", chunks: 90, toolEnding: false },
        { label: "tool", chunks: 18, toolEnding: true },
      ]) {
        const turn = events.length;
        const marker = `Settle ${scenario.label} marker ${turn}`;
        await sample(page, marker);
        await stream(`settle-${turn}`, `Settle ${scenario.label}`, marker, scenario.chunks, (index) => {
          if (scenario.toolEnding && index === scenario.chunks - 1) toolCall(`settle-tool-${turn}`);
        });
        if (scenario.toolEnding) toolDone(`settle-tool-${turn}`);
        // The reply, and a tool-ending reply's tool row, paint and come to rest while the turn still
        // runs, before the turn ends, so the last frame before the settle is that state: a one-chunk
        // reply and its end could land in one WebKit frame, and on the CI runner the tool row and
        // the turn's end landed in one Chromium frame, which hid the tool row's fold.
        await page.waitForFunction(() => {
          const frames = (window as unknown as { __frames: Frame[] }).__frames;
          return frames.some((frame) => frame.messageBottom !== undefined && !frame.settled);
        });
        await rest(page);
        endTurn();
        await ended(page, marker);
        await rest(page);
        const frames = await stop(page);
        const measured = frames.filter(
          (frame) =>
            frame.messageBottom !== undefined &&
            frame.composerTop !== undefined &&
            Number.isFinite(frame.messageBottom) &&
            Number.isFinite(frame.composerTop),
        );
        const before = measured.filter((frame) => !frame.settled).at(-1);
        const after = measured.find((frame) => frame.settled);
        expect({
          scenario: scenario.label,
          samples: measured.length,
          before: Boolean(before),
          after: Boolean(after),
        }).toEqual({
          scenario: scenario.label,
          samples: expect.any(Number),
          before: true,
          after: true,
        });
        expect(Math.abs(after!.composerTop! - before!.composerTop!)).toBeLessThanOrEqual(1);
        const moved = after!.messageBottom! - before!.messageBottom!;
        if (!scenario.toolEnding) expect(Math.abs(moved)).toBeLessThanOrEqual(1);
        else {
          // A finished turn folds its tool rows into "Worked for" above the reply (80e6a34d0b9c,
          // on purpose): the tool row that ran after the reply leaves from under it, so the reply
          // drops by what went from under it, once, in the settle's frame, and rests there.
          const left = before!.under! - after!.under!;
          expect(left).toBeGreaterThan(20);
          expect(Math.abs(moved - left)).toBeLessThanOrEqual(1);
          const rested = measured.filter((frame) => frame.settled).map((frame) => frame.messageBottom!);
          expect(Math.max(...rested) - Math.min(...rested)).toBeLessThanOrEqual(1);
        }
      }
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: a queued prompt sent as the next turn moves the view up only",
    async (name) => {
      const page = await open(name);
      const turn = events.length;
      const marker = `Queue marker ${turn}`;
      await sample(page, marker);
      await stream(`p-${turn}`, `Queue turn ${turn}`, marker, 60, (index) => {
        if (index === 20) enqueue(`q-${turn}`, "then write the changelog line for it");
      });
      endTurn();
      // acpmux sends the queued prompt as the turn ends: its card leaves as its bubble arrives.
      unqueue("dequeued", `q-${turn}`);
      await stream(`q-${turn}`, "then write the changelog line for it", `Next marker ${turn}`, 30);
      endTurn();
      await ended(page, `Next marker ${turn}`);
      await rest(page);
      const frames = await stop(page);
      expect({ drops: drops(frames), atEnd: (await fromEnd(page)) <= 4 }).toEqual({ drops: [], atEnd: true });
      await page.close();
    },
  );

  test.each(engines.map(([name]) => name))(
    "%s: scrolling up while a reply streams is never pulled back",
    async (name) => {
      const page = await open(name);
      const turn = events.length;
      const box = (await page.locator(".acpmux-scroll").boundingBox())!;
      let wheeled: Promise<number> | undefined;
      await stream(`p-${turn}`, `Wheel turn ${turn}`, `Wheel marker ${turn}`, 90, (index) => {
        if (index === 30)
          wheeled = page.mouse
            .move(box.x + box.width / 2, box.y + 120)
            .then(() => page.mouse.wheel(0, -400))
            .then(() => settledScrollTop(page));
      });
      const left = await wheeled!;
      endTurn();
      await ended(page, `Wheel marker ${turn}`);
      await rest(page);
      expect({ kept: Math.abs((await scrollTop(page)) - left) <= 1, behind: (await fromEnd(page)) > 200 }).toEqual({
        kept: true,
        behind: true,
      });
      await page.close();
    },
  );

  // The same with a grown composer: the reader typed five lines (the rows are drawn up by the card's
  // growth while the view follows) when the queued prompt is sent. The queue card leaving and its
  // prompt arriving move the reply only up on every painted frame: the room held for the prompt
  // keeps the rows where they were drawn, and never drops them by the card, then lifts them back.
  test.each(engines.map(([name]) => name))(
    "%s: a queued prompt sent while the composer is grown moves the view up only",
    async (name) => {
      const page = await open(name);
      const turn = events.length;
      const marker = `Grown marker ${turn}`;
      // fixed-wait: stream() paces the reply's chunks as acpmux sends them; the cadence is the behavior.
      await stream(`p-${turn}`, `Grown turn ${turn}`, marker, 40, (index) => {
        if (index === 10) enqueue(`q-${turn}`, "then write the changelog line for it");
      });
      await page.locator(".acpmux-queued").first().waitFor();
      await painted(page, 12);
      await page.locator(".acpmux-md-field").first().click();
      for (let line = 1; line <= 5; line++) {
        await page.keyboard.type(`Line ${line} of a draft`);
        await page.keyboard.press("Shift+Enter");
        await painted(page, 3);
      }
      await painted(page, 12);
      await sample(page, marker);
      endTurn();
      // acpmux sends the queued prompt as the turn ends: its card leaves as its bubble arrives.
      unqueue("dequeued", `q-${turn}`);
      // fixed-wait: stream() paces the reply's chunks as acpmux sends them; the cadence is the behavior.
      await stream(`q-${turn}`, "then write the changelog line for it", `Next grown marker ${turn}`, 30);
      endTurn();
      await page.getByText(`Next grown marker ${turn}`).waitFor();
      await painted(page, 40);
      const frames = await stop(page);
      expect(frames.filter((frame) => frame.marker !== undefined).length).toBeGreaterThan(5);
      expect({ drops: drops(frames), atEnd: (await fromEnd(page)) <= 4 }).toEqual({ drops: [], atEnd: true });
      await page.close();
    },
  );

  /// How far the last row sits above the bottom stack's top, once the transcript is at rest. A new row
  /// rises in (cv-enter); a read mid-way put the row up to 41px low in Chromium on a loaded machine,
  /// though scrollTop never moved. Infinite ones (a spinner) aside.
  const gapAbove = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector(".acpmux-scroll")!;
      for (;;) {
        const moving = document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" &&
              Number.isFinite(animation.effect?.getComputedTiming().endTime) &&
              animation.effect instanceof KeyframeEffect &&
              animation.effect.target instanceof Node &&
              scroller.contains(animation.effect.target),
          );
        if (moving.length === 0) break;
        await Promise.allSettled(moving.map((animation) => animation.finished));
      }
      const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row")];
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      return Math.round(
        document.querySelector(".acpmux-dock")!.getBoundingClientRect().top - last.getBoundingClientRect().bottom,
      );
    });

  /// From the first painted frame, once it starts, without the queue card: how long, in ms, until the
  /// last row rests `resting` px over the stack's top again with nothing in the transcript moving.
  /// `closed` reads it (Infinity if it never comes back within 600 frames).
  const watchGap = (page: Page, resting: number) =>
    page.evaluate((resting) => {
      const w = window as unknown as { __closed: Promise<number> };
      const scroller = document.querySelector(".acpmux-scroll")!;
      w.__closed = new Promise<number>((resolve) => {
        let left: number | undefined;
        let frames = 0;
        window.cmuxAfterPaint((now) => {
          if (++frames > 600) {
            resolve(Infinity);
            return false;
          }
          if (left === undefined) {
            if (document.querySelector(".acpmux-queued")) return;
            left = now;
          }
          const moving = document
            .getAnimations()
            .some(
              (animation) =>
                animation.playState === "running" &&
                Number.isFinite(animation.effect?.getComputedTiming().endTime) &&
                animation.effect instanceof KeyframeEffect &&
                animation.effect.target instanceof Node &&
                scroller.contains(animation.effect.target),
            );
          const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
          const last = rows.reduce((a, b) =>
            Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
          );
          const gap =
            document.querySelector(".acpmux-dock")!.getBoundingClientRect().top - last.getBoundingClientRect().bottom;
          if (moving || Math.abs(Math.round(gap) - resting) > 4) return;
          resolve(now - left);
          return false;
        });
      });
    }, resting);
  const closed = (page: Page) =>
    page.evaluate(async () => Math.round(await (window as unknown as { __closed: Promise<number> }).__closed));

  test.each(engines.map(([name]) => name))(
    "%s: a queued prompt deleted while the turn runs a tool leaves no gap for long",
    async (name) => {
      const page = await open(name);
      const turn = events.length;
      await stream(`p-${turn}`, `Busy turn ${turn}`, `Busy marker ${turn}`, 30, (index) => {
        if (index === 10) enqueue(`q-${turn}`, "never mind this one either");
      });
      // The turn runs a tool: nothing streams while the prompt is deleted.
      toolCall(`t-${turn}`);
      await page.locator(".acpmux-queued").waitFor();
      await page.getByText("ls -la").first().waitFor();
      await rest(page);
      const resting = await gapAbove(page);
      await watchGap(page, resting);
      unqueue("queue_removed", `q-${turn}`);
      const after = await closed(page);
      toolDone(`t-${turn}`);
      endTurn();
      // The last row rests on the stack's top again, a card's height lower, well before a second:
      // the room held for the withdrawn prompt (250ms) goes within 600ms. The 180ms on top was the
      // growth glide's, which #23807 removed; it stays as slack for a loaded runner.
      expect({ after: after <= 600 + 180, atEnd: (await fromEnd(page)) <= 4 }).toEqual({ after: true, atEnd: true });
      await page.close();
    },
  );

  test.each(engines.flatMap(([name]) => [`${name} event first`, `${name} queue first`]))(
    "%s: a deleted queued prompt leaves no gap under the last row",
    async (label) => {
      const [name, order] = label.split(" ");
      const page = await open(name!);
      const turn = events.length;
      await stream(`p-${turn}`, `Delete turn ${turn}`, `Delete marker ${turn}`, 30);
      endTurn();
      await ended(page, `Delete marker ${turn}`);
      await rest(page);
      const resting = await gapAbove(page);
      enqueue(`q-${turn}`, "never mind this one");
      await page.locator(".acpmux-queued").waitFor();
      await rest(page);
      if (order === "queue") {
        // acpmux's queue update can come before its `queue_removed` record.
        queue = [];
        changed();
        // The page has taken the update on its own: the card leaves with it. Timed from the record.
        await page.locator(".acpmux-queued").waitFor({ state: "detached" });
        await watchGap(page, resting);
        emit("mux", "queue_removed", { promptId: `q-${turn}` });
      } else {
        await watchGap(page, resting);
        unqueue("queue_removed", `q-${turn}`);
      }
      const after = await closed(page);
      expect({ after: after <= 300, atEnd: (await fromEnd(page)) <= 4 }).toEqual({ after: true, atEnd: true });
      await page.close();
    },
  );
});
