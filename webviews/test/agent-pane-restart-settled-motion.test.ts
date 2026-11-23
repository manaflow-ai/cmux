// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// Leo, 2026-11-22 ~21:47Z, after restarting cmux NIGHTLY to update: "the crazy fucking stupid folding
// animations somehow replay even though these messages had already been seen by me".
//
// The rule (cmuxterm-hq docs/design/transcript-animation-rules.md): an animation plays only for a
// change the reader caused or is watching live. A relaunch restores what the reader already saw, so
// the restored chat draws settled from its first frame: no fold, no entrance, no FLIP, no fade on any
// row that was there before the quit.
//
// The real pane's dev entry opens a chat from a stand-in acpmux (as agent-pane-settled-load does),
// the page quits (pagehide hands the host its kept tail and reading place, as the app's quit does),
// and a second page opens it cold, as after the restart. From the second page's first script on,
// every animation that starts in the page is recorded: CSS transitions (`transitionrun`), CSS
// animations (`animationstart`) and Web Animations (`Element.animate`, with its caller). Loops
// (infinite iterations: spinners, shimmers) are ambient and not counted. The shipped experiment arms
// are used, not pinned, since the folds are what is measured. One JSON line per case
// (`restart-motion:`) is the PR's before/after number.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadTurn, streamedReply, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-restart-settled-motion.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  const only = process.env.RESTART_MOTION_ENGINES?.split(",");
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`agent-pane-restart-settled-motion: skipping ${engine[0]}: ${String(error).slice(0, 400)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("a restarted chat draws settled", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000f2";
  const TURNS = 24;
  const CHUNK = 24;
  const base = 1_791_000_000_000;
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  let status = "idle";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Restart motion",
    harness: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: TURNS + 1,
    createdAt: base,
    updatedAt: base + TURNS * 60_000,
  });
  const record = (dir: string, kind: string, msg: Record<string, unknown>, at = Date.now()): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at, dir, kind, msg };
    events.push(event);
    return event;
  };
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: `agent-${SESSION}`, update: body },
  });
  const recordStep = (step: LoadStep, turn: number, at: number) => {
    if ("update" in step) {
      const body = step.update as Record<string, any>;
      if (body.sessionUpdate === "agent_message_chunk" && typeof body.content?.text === "string") {
        const text = body.content.text as string;
        for (let i = 0; i < text.length; i += CHUNK)
          record(
            "in",
            "agent_message_chunk",
            update({ ...body, messageId: `m-${turn}`, content: { type: "text", text: text.slice(i, i + CHUNK) } }),
            at,
          );
        return;
      }
      record("in", String(body.sessionUpdate), update(body), at);
    } else if (step.mux === "user_message") record("mux", "user_message", { ...step.msg, promptId: `p-${turn}` }, at);
    else if (step.mux === "turn_started")
      record("mux", "turn_started", { turnId: `t-${turn}`, promptId: `p-${turn}` }, at);
    else record("mux", step.mux, step.msg ?? {}, at);
  };
  for (let turn = 0; turn < TURNS; turn++) {
    const at = base + turn * 60_000;
    for (const step of loadTurn(turn, { diffLines: 30, logLines: 30 })) recordStep(step, turn, at);
  }
  const historyEnd = events.length;

  /// A real chat (Leo's, scrubbed: test/fixtures/chat-sim): a Claude coordinator turn with
  /// subagents, background tasks and tool groups, as acpmux recorded it.
  const replayed: Event[] = readFileSync(
    path.join(import.meta.dir, "fixtures/chat-sim/replay-lane-session.ndjson"),
    "utf8",
  )
    .split("\n")
    .filter((line) => line.trim() !== "")
    .map((line) => JSON.parse(line) as Event);
  /// The real chat's records through `count`, under this test's chat id; status from its end.
  const loadReplay = (count: number) => {
    events.length = 0;
    for (const event of replayed.slice(0, count)) events.push({ ...event, sessionId: SESSION, seq: events.length + 1 });
    let running = false;
    for (const event of events)
      if (event.dir === "mux" && event.kind === "turn_started") running = true;
      else if (event.dir === "mux" && (event.kind === "turn_result" || event.kind === "turn_end")) running = false;
    status = running ? "running" : "idle";
  };
  /// The record count `into` records after the last turn started: a turn running at the quit.
  const replayCut = (into: number) => {
    let start = 0;
    replayed.forEach((event, index) => {
      if (event.dir === "mux" && event.kind === "turn_started") start = index;
    });
    return Math.min(replayed.length - 1, start + into);
  };

  /// The turn that runs at the quit: a prompt, a reply's start and a few finished tool calls, so the
  /// running turn shows its live line and its work in sight.
  const LIVE = TURNS;
  const startLiveTurn = () => {
    const at = Date.now() - 105_000;
    record("mux", "user_message", { text: `Turn ${LIVE}: now fix the last retry loop`, promptId: `p-${LIVE}` }, at);
    record("mux", "turn_started", { turnId: `t-${LIVE}`, promptId: `p-${LIVE}` }, at);
    const reply = streamedReply(LIVE, 1);
    for (let i = 0; i < reply.length; i += CHUNK)
      record(
        "in",
        "agent_message_chunk",
        update({
          sessionUpdate: "agent_message_chunk",
          messageId: "m-live",
          content: { type: "text", text: reply.slice(i, i + CHUNK) },
        }),
        at,
      );
    for (let n = 0; n < 4; n++) {
      record(
        "in",
        "tool_call",
        update({
          sessionUpdate: "tool_call",
          toolCallId: `live-run-${n}`,
          kind: "execute",
          title: `Run bun test src/retry${n}`,
          status: "in_progress",
          rawInput: { command: `bun test src/retry${n}` },
        }),
        at,
      );
      record(
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: `live-run-${n}`,
          status: "completed",
          rawOutput: { exit_code: 0 },
          content: [{ type: "content", content: { type: "text", text: `ok ${n}` } }],
        }),
        at,
      );
    }
    status = "running";
  };
  const endLiveTurn = () => {
    record(
      "in",
      "agent_message_chunk",
      update({
        sessionUpdate: "agent_message_chunk",
        messageId: "m-live-end",
        content: { type: "text", text: "\n\nAll four suites pass; the retry loop stops at the cap." },
      }),
    );
    record("mux", "turn_result", { status: "completed" });
    status = "idle";
  };

  const page = (params: Record<string, any>, attach: boolean) => {
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const limit = params.limit === undefined ? (attach ? 2000 : Infinity) : Math.max(1, Number(params.limit));
    const out: Event[] = [];
    let hasMore = false;
    const take = (event: Event) => {
      if (event.seq <= after || event.seq >= before) return true;
      if (out.length >= limit) return !(hasMore = true);
      out.push(event);
      return true;
    };
    if (newest) {
      for (let i = events.length - 1; i >= 0 && take(events[i]!); i -= 1);
      out.reverse();
    } else for (let i = 0; i < events.length && take(events[i]!); i += 1);
    return { events: out, hasMore };
  };
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [], capabilities: [] } },
        };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return {
          session: summary(),
          ...page(params, true),
          lastSeq: events.length,
          pageThrough: events.length,
          turnOpener: null,
        };
      case "_acpmux/events":
        return { ...page(params, false), lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
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

  /// Records every animation that starts in the page from its first script: one entry per start,
  /// with the row it is in, whether it is in the transcript and in its view, and (Web Animations) who
  /// called it. Loops are skipped.
  const recordMotion = (page: Page) =>
    page.addInitScript(() => {
      type Start = {
        kind: string;
        name: string;
        at: number;
        row?: string;
        el: string;
        transcript: boolean;
        inView: boolean;
        stack?: string;
      };
      const starts: Start[] = [];
      (window as unknown as { __motion: Start[] }).__motion = starts;
      const label = (el: Element) => {
        const cls = typeof el.className === "string" ? el.className : (el.getAttribute("class") ?? "");
        return `${el.tagName.toLowerCase()}.${cls.trim().split(/\s+/).slice(0, 3).join(".")}`;
      };
      const push = (kind: string, target: EventTarget | null, name: string, stack?: string) => {
        if (!(target instanceof Element)) return;
        const scroller = target.closest(".acpmux-scroll");
        let inView = false;
        if (scroller) {
          const a = target.getBoundingClientRect();
          const b = scroller.getBoundingClientRect();
          inView = a.bottom > b.top && a.top < b.bottom && a.width > 0;
        }
        starts.push({
          kind,
          name,
          at: Math.round(performance.now()),
          row: target.closest("[data-row-id]")?.getAttribute("data-row-id") ?? undefined,
          el: label(target),
          transcript: scroller !== null,
          inView,
          ...(stack ? { stack } : {}),
        });
      };
      addEventListener("transitionrun", (event) => push("transition", event.target, event.propertyName), true);
      addEventListener(
        "animationstart",
        (event) => {
          const target = event.target as Element;
          const style = getComputedStyle(target);
          const names = style.animationName.split(",").map((value) => value.trim());
          const counts = style.animationIterationCount.split(",").map((value) => value.trim());
          const index = Math.max(0, names.indexOf(event.animationName));
          if ((counts[index] ?? counts[0]) === "infinite") return;
          push("css", target, event.animationName);
        },
        true,
      );
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (this: Element, keyframes, options) {
        const made = animate.call(this, keyframes, options);
        const iterations = typeof options === "object" ? options?.iterations : undefined;
        if (iterations !== Infinity) {
          const frames = Array.isArray(keyframes) ? keyframes : keyframes ? [keyframes] : [];
          const props = [...new Set(frames.flatMap((frame) => Object.keys(frame ?? {})))]
            .filter((key) => !["offset", "easing", "composite"].includes(key))
            .join("+");
          const stack = (new Error().stack ?? "")
            .split("\n")
            .slice(2, 6)
            .map((line) =>
              line
                .trim()
                .replace(/https?:\/\/[^/]+\//, "")
                .replace(/\?[^:]*/, ""),
            )
            .join(" < ");
          push("waapi", this, props, stack);
        }
        return made;
      } as typeof Element.prototype.animate;
    });

  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);

  /// Opens the chat, lets it settle, then quits it: what the host keeps of the page (its tail and
  /// reading place), as the app's quit leaves it.
  const openAndQuit = async (name: string) => {
    const kept = { tails: {}, anchors: {} };
    const before = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
    try {
      await before.addInitScript((value) => {
        (globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept = value;
      }, kept);
      await installPaintedFrames(before);
      await before.goto(url());
      await before.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
      await frames(before, 90);
      await before.evaluate(() => dispatchEvent(new PageTransitionEvent("pagehide", { persisted: false })));
      Object.assign(
        kept,
        await before.evaluate(() =>
          JSON.parse(JSON.stringify((globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept)),
        ),
      );
    } finally {
      await before.close();
    }
    return kept;
  };

  type Start = {
    kind: string;
    name: string;
    at: number;
    row?: string;
    el: string;
    transcript: boolean;
    inView: boolean;
    stack?: string;
  };
  /// Opens the chat cold with what the host kept, waits for it to settle (~3 s of frames), and
  /// returns every animation start the page recorded.
  const restart = async (name: string, kept: unknown) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
    try {
      await page.addInitScript((value) => {
        (globalThis as { cmuxDevHostKept?: unknown }).cmuxDevHostKept = value;
      }, kept);
      await installPaintedFrames(page);
      await recordMotion(page);
      await page.goto(url());
      await page.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
      await frames(page, 240);
      return await page.evaluate(() => (window as unknown as { __motion: Start[] }).__motion);
    } finally {
      await page.close();
    }
  };

  /// The scroll rail (threadMinimap) draws in the scroller too: item 5's, counted apart.
  const RAIL = /acpmux-minimap/;
  const report = (name: string, scenario: string, starts: Start[]) => {
    const rows = starts.filter((start) => start.transcript && !RAIL.test(start.el));
    const groups = new Map<string, number>();
    for (const start of starts) {
      const key = `${start.kind}:${start.name}:${start.el}${start.stack ? ` @ ${start.stack}` : ""}`;
      groups.set(key, (groups.get(key) ?? 0) + 1);
    }
    const line = {
      engine: name,
      case: scenario,
      starts: starts.length,
      transcript_starts: rows.length,
      transcript_in_view: rows.filter((start) => start.inView).length,
      rail_starts: starts.filter((start) => RAIL.test(start.el)).length,
      top: [...groups].sort((a, b) => b[1] - a[1]).slice(0, 25),
    };
    console.log(`restart-motion: ${JSON.stringify(line)}`);
    return line;
  };

  for (const scenario of ["idle", "running", "ended-while-closed"] as const)
    test.each(engines.map(([name]) => name))(
      `%s: a restarted chat draws settled, no row animates (${scenario})`,
      async (name) => {
        events.length = historyEnd;
        status = "idle";
        if (scenario !== "idle") startLiveTurn();
        const kept = await openAndQuit(name);
        if (scenario === "ended-while-closed") endLiveTurn();
        const starts = await restart(name, kept);
        const line = report(name, scenario, starts);
        expect(line.transcript_starts).toBe(0);
      },
    );

  // The real chat: at rest at the quit; a turn running at the quit and still running at the restart;
  // a turn running at the quit that went on (tools, subagents finishing) while the app was closed.
  for (const scenario of ["replay-idle", "replay-running", "replay-went-on", "replay-ended"] as const)
    test.each(engines.map(([name]) => name))(
      `%s: a restarted real chat draws settled, no row animates (${scenario})`,
      async (name) => {
        const into = { "replay-running": 400, "replay-went-on": 150, "replay-ended": 600 } as const;
        loadReplay(scenario === "replay-idle" ? replayed.length : replayCut(into[scenario]));
        const kept = await openAndQuit(name);
        if (scenario === "replay-went-on") loadReplay(replayCut(600));
        // The turn running at the quit ended while the app was closed: its work folds under "Worked for".
        if (scenario === "replay-ended") loadReplay(replayed.length);
        const starts = await restart(name, kept);
        const line = report(name, scenario, starts);
        expect(line.transcript_starts).toBe(0);
      },
    );
});
