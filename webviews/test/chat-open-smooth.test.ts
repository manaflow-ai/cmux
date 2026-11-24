// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Opening a chat is one motion (https://github.com/manaflow-ai/cmux/issues/48498: "loading chats
// scrolls randomly up and down, loads jaggedly, and shifts layout"). The first painted frame that
// shows the chat is already its final state: at the latest message, every row at the place it keeps,
// the composer where it stays. Nothing after it moves, blanks or refills in steps.
//
// The real pane's dev entry opens chats from a stand-in acpmux that pages them as acpmux does (the
// newest `limit` records on attach, older pages on `_acpmux/events beforeSeq`). The chats are what a
// reader opens, not one line per reply: Markdown with headings, wrapping tables, lists, quotes and code
// blocks, long tool output, and screenshots (a reply's inline image and a Read's image result).
// Each case records every painted frame (support/paintedFrames.ts) from navigation, or from the
// sidebar's `chat.select` for a switch: the rows in view (id and top), the composer's box and the
// scroller's offset, and judges them with firstLoadFrames.ts `classifyFrames`, as the flicker log does:
//   shifts    frames after the first content in which a row in view or the composer moved, or the
//             bottom row was replaced;
//   blank     frames after the first content with no row in view;
//   reversals the scroller's offset changing direction after the first content (up then down, down
//             then up): the "random scrolling" of the report;
//   settled   the first frame of the final state, which must be the first content frame.
// Both engines: the Mac app draws the pane in WebKit; Chromium is the browser slot's.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadTurn, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { classifyFrames, type FrameRecord } from "../src/agent-session/acpmux/firstLoadFrames";
import { pngBase64 } from "../bench/godFixture";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-open-smooth.test.ts", async () => {
  setDefaultTimeout(560_000);
  const only = process.env.SMOOTH_OPEN_ENGINES?.split(",");
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`chat-open-smooth: skipping ${engine[0]}: ${String(error).slice(0, 300)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("a chat opens in one motion", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const START = Date.UTC(2026, 10, 1, 9, 0, 0);
  /// Nothing in view changed this long after the last change: the open is over.
  const QUIET_MS = 1500;
  const LIMIT_MS = 20_000;

  /// A reply as an agent writes one when it explains a change: every block kind the transcript
  /// estimates (model.ts) and then draws at its own height.
  const richReply = (turn: number) =>
    `## What changed in step ${turn}\n\n` +
    `The guard in \`step${turn}.ts\` compared the running total before it was clamped, so a value past ` +
    `the ceiling slipped through whenever the first pass already sat near the limit. `.repeat(3) +
    "\n\n| Case | Before | After | Notes |\n| --- | --- | --- | --- |\n" +
    Array.from(
      { length: 4 },
      (_, row) =>
        `| case ${row} | ${row * turn} passes the ceiling | clamped at ${row * 7} | the long note for this row wraps across ` +
        `two or three lines in a narrow column so its height is only known once drawn |`,
    ).join("\n") +
    "\n\n> Note: the old name stays as an alias for one release, so callers outside the package keep building.\n\n" +
    "1. Clamp first\n2. Then compare\n   - nested detail one\n   - nested detail two\n3. Rerun the suite\n\n" +
    (turn % 3 === 0
      ? `The bound is\n\n$$\\sum_{i=0}^{${turn + 3}} \\frac{x_i^2}{\\sqrt{c + i}} \\le \\lceil L \\rceil$$\n\n`
      : "") +
    (turn % 4 === 2
      ? "```mermaid\nflowchart TD\n  A[total] --> B{past ceiling?}\n  B -->|yes| C[clamp]\n  B -->|no| D[keep]\n  C --> E[compare]\n  D --> E\n```\n\n"
      : "") +
    (turn % 2 === 0
      ? `Here is the chart after the fix:\n\n![chart ${turn}](data:image/png;base64,${pngBase64(turn, 240)})\n\n`
      : "") +
    "```ts\n" +
    Array.from(
      { length: 6 + (turn % 5) },
      (_, line) => `export const value${line} = clamp(total${line}, ceiling);`,
    ).join("\n") +
    "\n```\n\n" +
    `That covers step ${turn}.\n`;

  const richTurn = (turn: number): LoadStep[] => {
    const steps = loadTurn(turn, { diffLines: 40, logLines: 60 });
    const end = steps.findIndex((step) => "mux" in step && step.mux === "turn_result");
    const extra: LoadStep[] = [
      { update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: `\n\n${richReply(turn)}` } } },
    ];
    if (turn % 3 === 1)
      extra.unshift({
        update: {
          sessionUpdate: "tool_call",
          toolCallId: `smooth-shot-${turn}`,
          kind: "read",
          title: `Read screenshots/turn-${turn}.png`,
          status: "completed",
          locations: [{ path: `/mock/project/screenshots/turn-${turn}.png` }],
          content: [{ type: "content", content: { type: "image", mimeType: "image/png", data: pngBase64(turn, 320) } }],
        },
      });
    steps.splice(end, 0, ...extra);
    return steps;
  };

  type Chat = { id: string; title: string; turns: number; events: Record<string, unknown>[]; latest: string };
  const chat = (id: string, title: string, turns: number): Chat => {
    const events: Record<string, unknown>[] = [];
    for (let turn = 0; turn < turns; turn += 1)
      for (const step of richTurn(turn)) {
        const seq = events.length + 1;
        events.push(
          "update" in step
            ? {
                sessionId: id,
                seq,
                at: START + turn * 60_000,
                dir: "in",
                kind: String(step.update.sessionUpdate),
                msg: { method: "session/update", params: { sessionId: id, update: step.update } },
              }
            : { sessionId: id, seq, at: START + turn * 60_000, dir: "mux", kind: step.mux, msg: step.msg ?? {} },
        );
      }
    // The chat's last line: in view only when the chat is at its latest message.
    return { id, title, turns, events, latest: `That covers step ${turns - 1}.` };
  };
  const chats = [
    chat("0190a000-0000-7000-8000-000000048498", "Rich long chat", 60),
    chat("0190a000-0000-7000-8000-000000048499", "Rich other chat", 40),
    chat("0190a000-0000-7000-8000-00000004849a", "Rich short chat", 2),
  ];
  const [LONG, OTHER, SHORT] = chats as [Chat, Chat, Chat];
  const listed = (c: Chat) => ({
    sessionId: c.id,
    cwd: "/mock/project",
    title: c.title,
    harness: "claude",
    family: "claude",
    model: "claude-sonnet",
    status: "idle",
    turnCount: c.turns,
    createdAt: START,
    updatedAt: START + c.turns * 60_000 + chats.indexOf(c),
    currentModeId: "default",
  });
  const page = (c: Chat, params: Record<string, any>) => {
    const before = typeof params.beforeSeq === "number" ? params.beforeSeq : Number.POSITIVE_INFINITY;
    const held = c.events.filter((event) => (event.seq as number) < before);
    const limit = typeof params.limit === "number" ? params.limit : held.length;
    const taken = held.slice(Math.max(0, held.length - limit));
    return { events: taken, hasMore: taken.length < held.length, lastSeq: c.events.length };
  };
  const find = (params: Record<string, any>) => chats.find((c) => c.id === params.sessionId) ?? LONG;
  const answer = (method: string, params: Record<string, any>): unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: chats.map(listed) };
      case "_acpmux/attach":
        return { session: listed(find(params)), ...page(find(params), params) };
      case "_acpmux/events":
        return page(find(params), params);
      case "acp.trust.get":
        return { cwd: "/mock/project", level: "trusted" };
      default:
        return null;
    }
  };

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
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
          const result = answer(message.method, message.params ?? {});
          // A local daemon's round trip; an attach of a long chat costs a little more.
          setTimeout(
            () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result })),
            message.method === "_acpmux/attach" ? 60 : 15,
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
  });
  afterAll(async () => {
    await vite?.close();
    await daemon?.stop(true);
  });

  type Recorded = { frames: (FrameRecord & { marker: boolean })[]; started: number; painted: number | null };
  /// Runs in the page: records each painted frame from the call until nothing in view changed for
  /// `quietMs` after `marker` first showed (or `limitMs`), into `window.__smoothOpen`.
  const recorder = ({
    marker,
    quietMs,
    limitMs,
    rowSelector,
  }: {
    marker: string;
    quietMs: number;
    limitMs: number;
    rowSelector: string;
  }) => {
    const started = performance.now();
    const frames: (FrameRecord & { marker: boolean })[] = [];
    let last = "";
    let changedAt = started;
    let seen = false;
    let first: () => void = () => {};
    (window as unknown as { __smoothOpenStarted: Promise<void> }).__smoothOpenStarted = new Promise<void>((resolve) => {
      first = resolve;
    });
    const done = new Promise<Recorded>((resolve) => {
      window.cmuxAfterPaint(() => {
        const now = performance.now();
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const hidden = document.getElementById("root")?.style.opacity === "0";
        const view = scroller && !hidden ? scroller.getBoundingClientRect() : undefined;
        const rows: { id: string; top: number }[] = [];
        let marked = false;
        // Rows under a running fade (the opened chat's fade in, from 0) are shown, fading in; rows at
        // opacity 0 with none (held unseen) are not: the pane is empty there.
        const fading = scroller?.getAnimations?.().some((animation) => animation.playState === "running") ?? false;
        if (view && (fading || Number(getComputedStyle(scroller!).opacity) > 0))
          for (const row of Array.from(scroller!.querySelectorAll<HTMLElement>(rowSelector))) {
            const box = row.getBoundingClientRect();
            if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
            rows.push({ id: row.dataset.rowId ?? "", top: box.top });
            if (!marked && (row.textContent ?? "").includes(marker)) marked = true;
          }
        rows.sort((a, b) => a.top - b.top);
        const composer = Array.from(document.querySelectorAll(".acpmux-composer-box"))
          .map((element) => element.getBoundingClientRect())
          .find((box) => box.height > 0);
        const frame = {
          t: now,
          copyShown: false,
          rows,
          composer: composer ? { top: composer.top, height: composer.height } : null,
          scrollTop: scroller && !hidden ? scroller.scrollTop : null,
          marker: marked,
        };
        if (marked) seen = true;
        const signature = JSON.stringify([
          rows.map((row) => [row.id, Math.round(row.top)]),
          frame.composer && [Math.round(frame.composer.top), Math.round(frame.composer.height)],
          frame.scrollTop === null ? null : Math.round(frame.scrollTop),
        ]);
        if (signature !== last) {
          last = signature;
          changedAt = now;
          frames.push(frame);
          if (frames.length === 1) first();
        }
        if (now - started < limitMs && (!seen || now - changedAt < quietMs)) return;
        const painted = (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt;
        resolve({ frames, started, painted: painted ?? null });
        return false;
      });
    });
    (window as unknown as { __smoothOpen: Promise<Recorded> }).__smoothOpen = done;
  };

  type Judged = {
    firstContent: number | null;
    settled: number | null;
    shifts: number;
    blank: number;
    reversals: number;
    atLatest: boolean;
    /// Every height the composer's box drew at, from its first frame (covered or not): the prompt
    /// field's editor is made a task or more after the field mounts, and the box grew when it came.
    composerHeights: number[];
    trace: string[];
  };
  /// The frames the reader sees, judged from the one that first showed the opened chat. For a page
  /// load that is the frame the reveal shows: the app covers the page until it tells its host it
  /// shows the chat (`pane.painted`, the dev host's `cmuxDevPaintedAt`), and a frame is recorded only
  /// when something changed, so the last frame before that moment is what the reveal shows (the first
  /// after it when none came before). For a switch it is the first frame recorded after the one
  /// before the switch. That frame must already be the latest
  /// message (`atLatest`): a chat shown blank, at its top or mid-way that then moves there fails.
  const judge = (recorded: Recorded, page: boolean): Judged => {
    let from = -1;
    if (page) {
      const after = recorded.painted ?? Number.POSITIVE_INFINITY;
      for (const [index, frame] of recorded.frames.entries()) if (frame.t < after) from = index;
      if (from < 0 || recorded.frames[from]!.rows.length === 0)
        from = recorded.frames.findIndex((frame) => frame.t >= after && frame.rows.length > 0);
    } else if (recorded.frames.length > 1) {
      // A frame is recorded only when what is in view changed, from just before the switch: the second
      // is the switch's first drawn frame, whatever it shows (rows of two chats can share an id).
      from = 1;
    }
    const frames = (from < 0 ? [] : recorded.frames.slice(from)).map((frame) => ({
      ...frame,
      t: frame.t - recorded.started,
    }));
    const metrics = classifyFrames(frames);
    let reversals = 0;
    let direction = 0;
    for (let at = 1; at < frames.length; at += 1) {
      const a = frames[at - 1]!.scrollTop;
      const b = frames[at]!.scrollTop;
      if (a === null || b === null || Math.abs(b - a) <= 1) continue;
      const now = Math.sign(b - a);
      if (direction !== 0 && now !== direction) reversals += 1;
      direction = now;
    }
    const trace = frames.slice(0, 24).map((frame, index) => {
      const why = metrics.shiftAt.find((shift) => shift.index === index)?.why;
      return `${frame.t.toFixed(0)}ms top=${frame.scrollTop?.toFixed(0)} rows=${frame.rows.length} composer=${frame.composer?.top.toFixed(0)}${why ? ` SHIFT ${why}` : ""}`;
    });
    return {
      firstContent: metrics.firstContentMs,
      settled: metrics.finalFirstPaintMs,
      shifts: metrics.shiftFrames,
      blank: metrics.blankAfterContent,
      reversals,
      atLatest: frames.length > 0 && frames[0]!.marker,
      composerHeights: [
        ...new Set(recorded.frames.flatMap((frame) => (frame.composer ? [Math.round(frame.composer.height)] : []))),
      ],
      trace,
    };
  };

  const record = async (tab: Page, marker: string, start: () => Promise<unknown>) => {
    await tab.evaluate(
      `(${recorder.toString()})(${JSON.stringify({ marker, quietMs: QUIET_MS, limitMs: LIMIT_MS, rowSelector: TRANSCRIPT_ROW })})`,
    );
    // The frame before the switch is recorded first, so the switch's own frames come after it.
    await tab.evaluate(() => (window as unknown as { __smoothOpenStarted: Promise<void> }).__smoothOpenStarted);
    await start();
    return judge(
      (await tab.evaluate(() => (window as unknown as { __smoothOpen: Promise<Recorded> }).__smoothOpen)) as Recorded,
      false,
    );
  };

  const holds = (name: string, judged: Judged) => {
    console.log(
      `::notice title=chat-open-smooth ${name}::first ${judged.firstContent?.toFixed(0)} ms, settled ${judged.settled?.toFixed(0)} ms, ` +
        `shifts ${judged.shifts}, blank ${judged.blank}, reversals ${judged.reversals}, composer ${judged.composerHeights.join("/")}\n  ${judged.trace.join("\n  ")}`,
    );
    expect(judged.firstContent).not.toBeNull();
    expect(judged.atLatest).toBe(true);
    expect({ shifts: judged.shifts, blank: judged.blank, reversals: judged.reversals }).toEqual({
      shifts: 0,
      blank: 0,
      reversals: 0,
    });
    // The first content frame was the final state: nothing came after it.
    expect(judged.settled).toBe(judged.firstContent);
    // The composer drew at one height from the first frame it showed in, before the reveal too.
    expect(judged.composerHeights.length).toBe(1);
  };

  for (const [engineName, engine] of engines)
    describe(`${engineName}`, () => {
      let browser: Browser | undefined;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
        // One load to warm Vite's transforms for this engine.
        const warm = await browser.newPage();
        await warm.goto(url(SHORT.id));
        await warm.getByText(SHORT.latest, { exact: false }).first().waitFor({ timeout: 90_000 });
        await warm.close();
      });
      afterAll(async () => {
        await browser?.close();
      });

      const coldOpen = async (c: Chat) => {
        const tab = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
        try {
          await installPaintedFrames(tab);
          await tab.addInitScript(
            `window.addEventListener("DOMContentLoaded", () => (${recorder.toString()})(${JSON.stringify({ marker: c.latest, quietMs: QUIET_MS, limitMs: LIMIT_MS, rowSelector: TRANSCRIPT_ROW })}))`,
          );
          await tab.goto(url(c.id));
          const recorded = (await tab.evaluate(
            () => (window as unknown as { __smoothOpen: Promise<Recorded> }).__smoothOpen,
          )) as Recorded;
          // The page told its host it shows the chat: the reveal is judged, not the last frame.
          expect(recorded.painted).not.toBeNull();
          return judge(recorded, true);
        } finally {
          await tab.close();
        }
      };

      test("a long rich chat opened cold lands at its latest message in one frame and holds still", async () => {
        for (let round = 0; round < 2; round += 1) holds(`${engineName} cold long #${round}`, await coldOpen(LONG));
      });

      test("a short rich chat opened cold lands in one frame and holds still", async () => {
        holds(`${engineName} cold short`, await coldOpen(SHORT));
      });

      test("switching to another rich chat lands at its latest message in one frame and holds still", async () => {
        const tab = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
        try {
          await installPaintedFrames(tab);
          await tab.goto(url(LONG.id));
          await tab.getByText(LONG.latest, { exact: false }).first().waitFor({ timeout: 60_000 });
          for (const [index, target] of [OTHER, LONG, SHORT, OTHER].entries())
            holds(
              `${engineName} switch #${index} to ${target.title}`,
              await record(tab, target.latest, () =>
                tab.evaluate(
                  (id) =>
                    (
                      window as unknown as {
                        cmuxAcpmuxActions: Record<string, (params: Record<string, unknown>) => Promise<unknown>>;
                      }
                    ).cmuxAcpmuxActions["chat.select"]!({ sessionId: id }),
                  target.id,
                ),
              ),
            );
        } finally {
          await tab.close();
        }
      });
    });
});
