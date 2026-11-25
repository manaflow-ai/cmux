// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
//
// Leo, 2026-11-22 ~21:47Z, after restarting cmux NIGHTLY to update: "composer dips down then goes back up".
//
// A relaunch restores what the reader left: the composer sits at its final place and size from the
// first frame the chat shows, and never moves after. The real pane's dev entry opens a chat from a
// stand-in acpmux, the page quits (pagehide hands the host its kept tail and reading place, as the
// app's quit does), and a second page opens it cold, as after the restart. Every painted frame from
// the first one that draws the composer with the chat's rows, the composer form, its box, its prompt
// and the dock that holds it are read; any move or resize past 1 px is a dip. One JSON line per case
// (`restart-composer:`) is the PR's before/after number.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { loadTurn, streamedReply, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-restart-composer-still.test.ts", async () => {
  setDefaultTimeout(400_000);
  const engines: [string, BrowserType][] = [];
  const only = process.env.RESTART_COMPOSER_ENGINES?.split(",");
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    if (only && !only.includes(engine[0])) continue;
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(`agent-pane-restart-composer-still: skipping ${engine[0]}: ${String(error).slice(0, 400)}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("a restarted chat keeps its composer still", () => test("no engine", () => {}));
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
  /// The chat's saved draft (acpmux's `_acpmux/draft_get`), or none.
  let draft: string | undefined;
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
      case "_acpmux/draft_get":
        return draft ? { draft } : null;
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

  type Box = { top: number; height: number };
  type Frame = { at: number; composer?: Box; box?: Box; dock?: Box; field?: Box; rows: number };
  /// Every painted frame's composer geometry, from the page's first script: the composer form, its
  /// box, its prompt and the dock that holds it. Nothing while the live root is held clear.
  const recordComposer = (page: Page) =>
    page.addInitScript(() => {
      type Box = { top: number; height: number };
      const frames: { at: number; rows: number; [part: string]: Box | number | undefined }[] = [];
      (window as unknown as { __composer: typeof frames }).__composer = frames;
      const read = (selector: string): Box | undefined => {
        const element = document.querySelector(selector);
        if (!element) return undefined;
        const rect = element.getBoundingClientRect();
        return rect.height > 0
          ? { top: Math.round(rect.top * 10) / 10, height: Math.round(rect.height * 10) / 10 }
          : undefined;
      };
      const tick = () => {
        const hidden = document.getElementById("root")?.style.opacity === "0";
        frames.push({
          at: Math.round(performance.now()),
          rows: hidden ? 0 : document.querySelectorAll(".acpmux-row").length,
          ...(hidden
            ? {}
            : {
                composer: read(".acpmux-composer"),
                box: read(".acpmux-composer-box"),
                field: read(".acpmux-composer-prompt"),
                dock: read(".acpmux-dock"),
              }),
        });
        // raf-read: getBoundingClientRect runs layout itself; each frame's sample is the layout the page
        // will paint, and a dip shows up as one sample's height, so no painted-frame wait is needed.
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    });

  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let i = 0; i < n; i++) await window.cmuxPaintFrame();
    }, count);

  /// Opens the chat, lets it settle, then quits it: what the host keeps of the page (its tail, its
  /// reading place and its drawn copy), as the app's quit leaves it. The copy is written as the app
  /// asks for it when the window goes away (chatSnapshot/live.ts `SNAPSHOT_WRITE_EVENT`).
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
      await before.evaluate(() => dispatchEvent(new Event("cmux-chat-snapshot-write")));
      await frames(before, 2);
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

  /// Opens the chat cold with what the host kept, lets it settle (240 painted frames), and returns
  /// its composer's frames. The chat's drawn copy is served as the app's `__snapshot/chat.js` serves
  /// it to a restored tab (AgentPaneChatSnapshots.swift `script`): the copy and the chat it is of.
  const restart = async (name: string, kept: unknown) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1200, height: 860 } });
    try {
      await page.addInitScript((value) => {
        const globals = globalThis as Record<string, unknown>;
        globals.cmuxDevHostKept = value;
        const copies = (value as { snapshots?: Record<string, { html?: unknown; draft?: unknown }> }).snapshots ?? {};
        const [chat, copy] = Object.entries(copies)[0] ?? [];
        globals.__cmuxChatSnapshot = typeof copy?.html === "string" ? copy : null;
        globals.__cmuxRestoredChat = chat ?? null;
        if (typeof copy?.draft === "string" && copy.draft) globals.__cmuxRestoredDraft = copy.draft;
      }, kept);
      await installPaintedFrames(page);
      await recordComposer(page);
      await page.goto(url());
      await page.locator(".acpmux-row").first().waitFor({ timeout: 60_000 });
      await frames(page, 240);
      return await page.evaluate(() => (window as unknown as { __composer: Frame[] }).__composer);
    } finally {
      await page.close();
    }
  };

  const PARTS = ["composer", "box", "field", "dock"] as const;
  const moved = (a: Box | undefined, b: Box | undefined) =>
    !!a && !!b && (Math.abs(a.top - b.top) > 1 || Math.abs(a.height - b.height) > 1);
  /// From the first frame that draws the composer with the chat's rows: the frames where a part moved
  /// or resized, and each part's largest move from where it first drew.
  const report = (name: string, scenario: string, all: Frame[]) => {
    const first = all.findIndex((frame) => frame.box !== undefined && frame.rows > 0);
    const shown = first < 0 ? [] : all.slice(first);
    const changes: { at: number; part: string; from: Box; to: Box }[] = [];
    for (let i = 1; i < shown.length; i++)
      for (const part of PARTS) {
        const a = shown[i - 1]![part];
        const b = shown[i]![part];
        if (moved(a, b)) changes.push({ at: shown[i]!.at, part, from: a!, to: b! });
      }
    const maxMove: Record<string, number> = {};
    for (const part of PARTS) {
      const origin = shown[0]?.[part];
      maxMove[part] = 0;
      for (const frame of shown) {
        const box = frame[part];
        if (origin && box)
          maxMove[part] = Math.max(
            maxMove[part]!,
            Math.abs(box.top - origin.top),
            Math.abs(box.height - origin.height),
          );
      }
    }
    const line = {
      engine: name,
      case: scenario,
      frames: shown.length,
      first_ms: shown[0]?.at ?? null,
      first: shown[0] ?? null,
      last: shown.at(-1) ?? null,
      change_frames: new Set(changes.map((change) => change.at)).size,
      max_move_px: maxMove,
      changes: changes.slice(0, 24),
    };
    console.log(`restart-composer: ${JSON.stringify(line)}`);
    return line;
  };

  const SAVED = "Before the restart I was writing this.\n\nIt has a second paragraph\n\nand a third one.";
  for (const scenario of ["idle", "running", "ended-while-closed", "idle-draft"] as const)
    test.each(engines.map(([name]) => name))(
      `%s: a restarted chat keeps its composer still (${scenario})`,
      async (name) => {
        events.length = historyEnd;
        status = "idle";
        draft = scenario === "idle-draft" ? SAVED : undefined;
        if (scenario === "running" || scenario === "ended-while-closed") startLiveTurn();
        const kept = await openAndQuit(name);
        if (scenario === "ended-while-closed") endLiveTurn();
        const line = report(name, scenario, await restart(name, kept));
        expect(line.frames).toBeGreaterThan(0);
        expect(line.change_frames).toBe(0);
      },
    );

  // The real chat (Leo's, scrubbed): at rest at the quit; a turn running at the quit and still
  // running at the restart (with and without a saved draft); one that went on while the app was
  // closed (tools, subagents finishing); one that ended meanwhile.
  for (const scenario of [
    "replay-idle",
    "replay-running",
    "replay-running-draft",
    "replay-went-on",
    "replay-ended",
  ] as const)
    // replay-went-on: the composer stays still; the dock still grows 34 px when the tray's pull hat
    // mounts after attach. That is the tray's settle-in (restore-settled item 2), whose change flips
    // this to `test` (`test.failing` fails once it passes).
    (scenario === "replay-went-on" ? test.failing : test).each(engines.map(([name]) => name))(
      `%s: a restarted real chat keeps its composer still (${scenario})`,
      async (name) => {
        const into = {
          "replay-running": 400,
          "replay-running-draft": 400,
          "replay-went-on": 150,
          "replay-ended": 600,
        } as const;
        draft = scenario === "replay-running-draft" ? SAVED : undefined;
        loadReplay(scenario === "replay-idle" ? replayed.length : replayCut(into[scenario]));
        const kept = await openAndQuit(name);
        if (scenario === "replay-went-on") loadReplay(replayCut(600));
        if (scenario === "replay-ended") loadReplay(replayed.length);
        const line = report(name, scenario, await restart(name, kept));
        expect(line.frames).toBeGreaterThan(0);
        expect(line.change_frames).toBe(0);
      },
    );
});
