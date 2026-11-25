// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The reader comes back to the latest row after a turn ended while they were scrolled up over its
// work (Leo, 2026-11-14: "and a resizing/re-adjustment of all chats after tool calls get folded";
// "also there's a tiny gap when i scroll to the bottom"). The turn's Worked for, left open over the
// work they read (cmux#24569, agent-pane-turn-end-keeps-place.test.ts), closes there in the turn's end
// motion, so nothing above the reply comes down in one frame; the newest row rests the rest gap
// over the bottom stack.
//
// The fold is seen by its attribute on the thread (turnEndFold.ts `TURN_END_ATTR`) as the reader
// wheels back; the gap is read as agent-pane-composer-rest-gap.test.ts reads it.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { REST_GAP } from "../src/agent-session/acpmux/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-turn-end-at-latest.test.ts", async () => {
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
      console.warn(
        `agent-pane-turn-end-keeps-place: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("turn end keeps place", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000e7";
  let status = "running";
  let family = "codex";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Retry policy",
    harness: "claude",
    // A finished turn folds its work under one Worked for: the Codex family's fold (turns.ts).
    family,
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 9,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const ran = (id: string, status = "completed") =>
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: `rg retry ${id}`,
      kind: "execute",
      status,
      rawInput: { command: `rg retry ${id}` },
    });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  // Finished turns above, so the reader can be scrolled into history too.
  for (let turn = 0; turn < 8; turn++) {
    record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops ` +
          "after five attempts. The fetch tests cover a server that fails twice and then answers.",
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  // The running turn: notes and tool calls, taller than the view.
  record("mux", "user_message", { text: "Find every retry loop and fix the cap", promptId: "p-live" });
  record("mux", "turn_started", {});
  for (let step = 0; step < 14; step++) {
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Checking call site ${step + 1}: it retries on every error, so the cap has to apply here as well. ` +
          "The loop sleeps a fixed second between attempts and never gives up, which is what made the upload " +
          "queue hammer the server during the outage last week.\n\n",
      ),
    );
    record("in", "tool_call", ran(`t${step}`));
  }
  /// The running turn's live line, the last row while it runs.
  const LIVE = "[data-row-id='thinking-live']";
  const opened = events.length;
  const REPLY =
    "Every retry loop now shares one capped backoff. The fetch client, the socket reconnect and the upload " +
    "queue each called their own sleep; they now call `backoff(attempt)`, which stops at eight seconds.\n\n" +
    "- fetch client\n- socket reconnect\n- upload queue\n\nFinal reply marker.";

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
        params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
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
    // A cold dev server's first load can run Vite's dependency optimizer and reload mid-compile.
    for (const browser of browsers.values()) {
      for (let attempt = 1; ; attempt++) {
        const warm = await browser.newPage();
        try {
          await warm.goto(url());
          await warm.locator(LIVE).waitFor({ timeout: 25_000 });
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

  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
  };

  /// Resolves once the transcript's offset and height have held, with nothing in it animating, for
  /// 12 painted frames.
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
      let last = "";
      for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
        held = now === last && !moving() ? held + 1 : 0;
        last = now;
      }
    });

  /// The call a reader scrolled into the running turn has in view (after "Checking call site 7").
  const MID = "t6";
  const midCall = events.findIndex(
    (event) =>
      event.kind === "tool_call" && (event.msg.params as { update: { toolCallId: string } }).update.toolCallId === MID,
  );
  async function open(name: string, midRunning = false) {
    events.length = opened;
    status = "running";
    // A command in an earlier run that still runs (a parallel `cp` while later calls go on): the
    // live line names it, and its run draws no row for it (turns.ts `codexRuns`, `lineCall`).
    events[midCall] = { ...events[midCall]!, msg: ran(MID, midRunning ? "in_progress" : "completed") };
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    // These pin the open live-turn arm: they read a running turn's work drawn in full, which the
    // shipped folded arm keeps under its Working for line (liveTurnWork.experiment.ts).
    await page.addInitScript(() => Object.assign(window, { cmuxExperiments: { "live-turn-work": "open" } }));
    await installPaintedFrames(page);
    await page.goto(url());
    await page.locator(LIVE).waitFor();
    await page.mouse.move(0, 0);
    await rest(page);
    // The reply streams in while the reader is at the end, before they scroll up.
    emit("in", "agent_message_chunk", chunk(REPLY));
    await page.getByText("Final reply marker.").waitFor();
    await rest(page);
    return page;
  }

  /// The gap between the newest row's line (its footer's action row once the turn ended) and the top
  /// of the bottom stack, as agent-pane-composer-rest-gap.test.ts reads it.
  const restGap = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
      const newest = rows.reduce<HTMLElement | undefined>(
        (a, b) => (!a || Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a),
        undefined,
      )!;
      const drawn = rows.filter((row) => row.getBoundingClientRect().height > 0);
      const last = drawn.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const actions = newest.querySelector(".cv-turn-actions");
      const bottom =
        newest !== last && newest.getBoundingClientRect().height === 0 && actions
          ? actions.getBoundingClientRect().bottom
          : last.getBoundingClientRect().bottom;
      const parts = [...dock.children].flatMap((part) =>
        part.classList.contains("acpmux-composer") ? [...part.children] : [part],
      );
      const top = Math.min(
        ...parts
          .map((part) => part.getBoundingClientRect())
          .filter((r) => r.height > 0)
          .map((r) => r.top),
      );
      const fromEnd = scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop;
      return {
        gap: Math.round((top - bottom) * 10) / 10,
        fromEnd,
        newest: newest.dataset.rowId,
        last: last.dataset.rowId,
        lastText: (last.textContent ?? "").slice(-60),
      };
    });

  // Leo, 2026-11-14: "and a resizing/re-adjustment of all chats after tool calls get folded". A turn
  // that ends while the reader is scrolled up over its work leaves its Worked for open (cmux#24569),
  // and it closes once they are back at the latest row. That close came in one frame, with no
  // motion: every row above the reply dropped by the work's height at once. It folds in the turn's
  // end motion now (conversation/turnEndFold.ts), the rows over it coming down together.
  // Leo, same message: "also there's a tiny gap when i scroll to the bottom". Back at the bottom the
  // newest row rests the rest gap (model.ts REST_GAP) over the bottom stack, with a subagent's tray
  // shown during the turn too.
  for (const [label, tray] of [
    ["plain", false],
    ["tray", true],
  ] as const)
    test.each(engines.map(([name]) => name))(
      `%s: ${label}: back at the latest row after the turn ended, its work folds in one motion and the rest gap holds`,
      async (name) => {
        family = "claude";
        const page = await open(name);
        if (tray) {
          emit("in", "subagent_spawned", {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "subagent_spawned" },
              _meta: { acpmux: { subagents: [{ id: "a1", parent: null, name: "Reviewer", state: "running" }] } },
            },
          });
          await page.locator(".acpmux-running-tray").waitFor({ timeout: 20_000 });
          await rest(page);
        }
        expect(Math.abs((await restGap(page)).gap - REST_GAP)).toBeLessThanOrEqual(1);
        // A little up: the turn's work stays in view, and the view no longer follows.
        await page.mouse.move(450, 300);
        await page.mouse.wheel(0, -160);
        await rest(page);
        status = "idle";
        emit("mux", "turn_result", { status: "completed" });
        changed();
        await rest(page);
        if (tray) {
          emit("in", "subagent_state_update", {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "subagent_state_update" },
              _meta: { acpmux: { subagents: [] } },
            },
          });
          await rest(page);
        }
        const worked = page.locator(".acpmux-worked button.cv-worked").last();
        expect(await worked.getAttribute("aria-expanded")).toBe("true");
        const work = await page
          .locator(".acpmux-scroll [data-row-id^='activity-']")
          .evaluateAll((rows) => rows.map((row) => row.getAttribute("data-row-id")!));
        expect(work.length).toBeGreaterThan(0);
        const fromEnd = () =>
          page.locator(".acpmux-scroll").evaluate((node) => node.scrollHeight - node.clientHeight - node.scrollTop);
        // Whether the turn's end fold played on the way back (turnEndFold.ts `TURN_END_ATTR`).
        await page.evaluate(() => {
          const w = window as unknown as { __folded: boolean };
          w.__folded = false;
          new MutationObserver(() => {
            if (document.querySelector("[data-turn-end-folding]")) w.__folded = true;
          }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["data-turn-end-folding"] });
        });
        for (let step = 0; step < 40 && (await fromEnd()) > 1; step++) {
          await page.mouse.wheel(0, 400);
          await rest(page);
        }
        await rest(page);
        await page.evaluate(async () => {
          for (let frame = 0; frame < 30; frame++) await window.cmuxPaintFrame();
        });
        // Back at the latest row the Worked for closed (cmux#24569, Lucas 2026-11-11: it always
        // closes once the turn ended), and it closed in the fold's motion, not in one frame.
        expect(await worked.getAttribute("aria-expanded")).toBe("false");
        expect(await page.evaluate(() => (window as unknown as { __folded: boolean }).__folded)).toBe(true);
        const end = await restGap(page);
        expect(end.fromEnd).toBeLessThanOrEqual(1);
        expect(Math.abs(end.gap - REST_GAP)).toBeLessThanOrEqual(1);
        await page.close();
      },
    );
});
