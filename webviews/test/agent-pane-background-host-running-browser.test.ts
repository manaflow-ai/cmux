// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Leo, 2026-11-22: "IF THIS IS THE CASE, THEN DON'T FUCKING DISPLAY THIS BULLSHIT LIKE THIS" and
// "WHAT THE HELL? WHY DID IT FUCKING DISPLAY NOTHING THEN COPY BUTTONS THEN YOU SENT SHIT THEN MY
// STEER WENT UNDER IT THEN FUCKKKK". A turn ended on its reply and footer, a background command's end
// woke the agent (`background_turn`), and acpmux's summary said a turn runs: the pane reopened the
// ended turn, drew an empty typing row under its footer and the turn's footer again under that, and
// Leo's next prompt went under both (background-turn-host-running.test.ts has the reducer's side).
//
// The real pane, from its dev entry, against a stand-in acpmux: every drawn row between the ended
// turn's footer and the next prompt is read on every painted frame, from the summary saying a turn
// runs until the prompt settles. None may be empty (no text, no control) and none may be a second
// footer of the prompt's turn. SHOT_DIR, when set, gets a screenshot of the settled pane.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-background-host-running-browser.test.ts", async () => {
  setDefaultTimeout(200_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    describe.skip("background turn the host runs", () => test("no chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000e9";
  let hostTurn: Record<string, unknown> | null = null;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/lanes",
    title: "Lane helpers",
    harness: "claude",
    family: "claude",
    status: hostTurn ? "running" : "idle",
    turn: hostTurn,
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
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const ran = (id: string, title: string) =>
    update({ sessionUpdate: "tool_call", toolCallId: id, title, kind: "execute", status: "completed" });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  record("mux", "user_message", { text: "Give every lane a helper", promptId: "p-1", turnId: "t1" });
  record("mux", "turn_started", { turnId: "t1" });
  record("in", "tool_call", ran("send", "SendMessage"));
  record("in", "agent_message_chunk", say("All six lanes now have a helper, each told to report back to you."));
  record("mux", "turn_result", { turnId: "t1", status: "completed" });
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
        params: { sessionId: SESSION, session: summary(), kind: "status", seq: events.length },
      }),
    );

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
  };

  type Band = { id: string; top: number; height: number; empty: boolean; footer: boolean };
  /// Every painted frame: the rows drawn between the prompt's footer (`summary-t1`) and the next prompt
  /// (or the end), each with whether it shows anything and whether it is an action row.
  const startSampling = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __bands: { frame: number; band: number; rows: Band[] }[]; __stop: () => void };
      w.__bands = [];
      let frame = 0;
      const read = () => {
        frame += 1;
        const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll [data-row-id]")];
        const from = rows.findIndex((row) => row.dataset.rowId === "summary-t1");
        if (from < 0) return;
        const out: Band[] = [];
        const footerBottom = rows[from]!.getBoundingClientRect().bottom;
        let band = 0;
        for (const row of rows.slice(from + 1)) {
          if (row.dataset.rowId?.startsWith("user-")) break;
          const box = row.getBoundingClientRect();
          if (box.height <= 0) continue;
          const shows =
            (row.innerText ?? "").trim().length > 0 || row.querySelector("button, svg, img, [role='button']") !== null;
          // The space from the footer to the first row that shows anything.
          if (shows && !out.some((seen) => !seen.empty)) band = box.top - footerBottom;
          out.push({
            id: row.dataset.rowId!,
            top: box.top,
            height: box.height,
            empty: !shows,
            footer: row.querySelector(".cv-turn-actions") !== null && !row.dataset.rowId!.startsWith("backgroundEnd-"),
          });
        }
        w.__bands.push({ frame, band, rows: out });
      };
      let on = true;
      w.__stop = () => (on = false);
      read();
      window.cmuxAfterPaint(() => {
        if (!on) return false;
        read();
        return true;
      });
    });

  const settle = (page: Page, frames = 30) =>
    page.evaluate(async (count) => {
      for (let at = 0; at < count; at += 1) await window.cmuxPaintFrame();
    }, frames);

  test("a background turn acpmux runs draws no empty row and no second footer under the ended turn", async () => {
    const page = await browser!.newPage({ viewport: { width: 760, height: 720 } });
    try {
      await installPaintedFrames(page);
      await page.goto(url());
      await page.locator("[data-row-id='summary-t1']").waitFor({ timeout: 30_000 });
      await settle(page);
      await startSampling(page);
      // Leo's records: the agent woke on its own (`background_turn`) and acpmux said a turn runs; a
      // background command finished meanwhile; his prompt ended the woken turn and opened its own.
      emit("mux", "background_turn", { state: "started", id: "bg-1", trigger: "system" });
      hostTurn = { turnId: "acp-bg-1", startedAt: Date.now() };
      changed();
      await settle(page);
      emit(
        "in",
        "background_task_update",
        update({
          sessionUpdate: "background_task_update",
          taskId: "bnzc3idfr",
          toolCallId: "bg-cmd",
          command: "wt new manaflow-ai/cmux lane/thought-row-feel",
          exitCode: 0,
          state: "completed",
          summary: 'Background command "wt new manaflow-ai/cmux lane/thought-row-feel" completed (exit code 0)',
        }),
      );
      await settle(page);
      if (process.env.SHOT_DIR) {
        fs.mkdirSync(process.env.SHOT_DIR, { recursive: true });
        await page.screenshot({ path: path.join(process.env.SHOT_DIR, "while-background-runs.png") });
      }
      emit("mux", "background_turn", { state: "ended", id: "bg-1", trigger: "system", quiet: true, reason: "prompt" });
      emit("mux", "user_message", { text: "Is the broker up for every lane?", promptId: "p-2", turnId: "t2" });
      await settle(page, 60);
      const frames = await page.evaluate(() => {
        const w = window as unknown as { __bands: { frame: number; band: number; rows: Band[] }[]; __stop: () => void };
        w.__stop();
        return w.__bands;
      });
      if (process.env.SHOT_DIR) {
        fs.mkdirSync(process.env.SHOT_DIR, { recursive: true });
        await page.screenshot({ path: path.join(process.env.SHOT_DIR, "after-next-prompt.png") });
      }
      const empty = frames.flatMap((f) => f.rows.filter((row) => row.empty).map((row) => ({ frame: f.frame, ...row })));
      const footers = frames.flatMap((f) =>
        f.rows.filter((row) => row.footer).map((row) => ({ frame: f.frame, ...row })),
      );
      const emptyPx = Math.max(
        0,
        ...frames.map((f) => f.rows.filter((r) => r.empty).reduce((s, r) => s + r.height, 0)),
      );
      console.log(
        `background-host-running: ${frames.length} frames, ${empty.length} empty-row samples (max ${emptyPx}px), ` +
          `${footers.length} second-footer samples, widest band under the footer ${Math.max(...frames.map((f) => f.band))}px; ids ${[...new Set([...empty, ...footers].map((r) => r.id))].join(",") || "none"}`,
      );
      expect(empty).toEqual([]);
      expect(footers).toEqual([]);
    } finally {
      await page.close();
    }
  });
});
