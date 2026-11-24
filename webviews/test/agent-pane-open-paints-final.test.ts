// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat opened after a restart paints once: the first frame that shows its rows is the final one.
// Leo, 2026-11-14: "i think the big issue is that there's just too much render shift when the thing
// restarts to update (i assume similar things occur for when it's manually restarted?) like it
// recalculates and stuff appears in sucession causing shifts". A relaunched pane opens its chat
// from nothing (no saved copy drew, or it was refused): the page attaches, and the rows, the
// composer and the folds must land where they stay, with no row moving and none popping in later.
//
// Every transcript row, the composer box and each of its controls is read on every painted frame from the page's start
// until the view rests, and scored with the shared box-shift measure (src/gallery/shift.ts,
// CLS-style). The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in
// acpmux that answers the attach with a long finished chat.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { scoreBoxFrames, type BoxFrame } from "../src/gallery/shift";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-open-paints-final.test.ts", async () => {
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
        `agent-pane-open-paints-final: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("open paints final", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000f1";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Retry policy",
    harness: "claude",
    family: "codex",
    status: "idle",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 10,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const ran = (id: string) =>
    update({
      sessionUpdate: "tool_call",
      toolCallId: id,
      title: `rg retry ${id}`,
      kind: "execute",
      status: "completed",
      rawInput: { command: `rg retry ${id}` },
    });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>) =>
    events.push({ sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg });
  // Finished turns, each with work that folds under its Worked for line, and a reply with a list and code.
  for (let turn = 0; turn < 10; turn++) {
    record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    for (let step = 0; step < 3; step++) record("in", "tool_call", ran(`t${turn}-${step}`));
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops after ` +
          "five attempts.\n\n- fetch client\n- socket reconnect\n\n```ts\nconst wait = backoff(attempt);\n```\n\n" +
          `Reply marker ${turn + 1}.`,
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
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
  const LAST = "Reply marker 10.";
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

  type Sample = { id: string; x: number; y: number; width: number; height: number };
  /// From the document's start, every painted frame's transcript rows in view and the composer box,
  /// in the window's coordinates.
  function sampleFromStart() {
    const w = window as unknown as { __frames: Sample[][]; __stop: () => void };
    w.__frames = [];
    let on = true;
    w.__stop = () => (on = false);
    const read = () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      if (!scroller) return;
      const view = scroller.getBoundingClientRect();
      const frame: Sample[] = [];
      for (const row of scroller.querySelectorAll<HTMLElement>("[data-row-id]")) {
        const box = row.getBoundingClientRect();
        if (box.height <= 0 || box.bottom <= view.top || box.top >= view.bottom) continue;
        frame.push({ id: `row ${row.dataset.rowId}`, x: box.x, y: box.y, width: box.width, height: box.height });
      }
      const composer = document.querySelector<HTMLElement>(".acpmux-composer-box, form.acpmux-composer");
      const box = composer?.getBoundingClientRect();
      if (box && box.height > 0)
        frame.push({ id: "composer", x: box.x, y: box.y, width: box.width, height: box.height });
      // Each of the composer's controls too (the model chip, the other chips, the context ring): one
      // that resizes or comes in after the first frame moves the row without moving the composer's box.
      // The Model chip widened 143 to 154 px and the ring came in late after a relaunch (ask-66b7d014c3).
      const controls = document.querySelectorAll<HTMLElement>(".acpmux-chips > *, .acpmux-context-ring");
      controls.forEach((control, index) => {
        const box = control.getBoundingClientRect();
        if (box.width <= 0 || box.height <= 0) return;
        const name = control.classList[0] ?? control.tagName.toLowerCase();
        frame.push({ id: `control ${index} ${name}`, x: box.x, y: box.y, width: box.width, height: box.height });
      });
      if (frame.some((sample) => sample.id.startsWith("row "))) w.__frames.push(frame);
    };
    const start = () =>
      window.cmuxAfterPaint(() => {
        if (!on) return false;
        read();
        return true;
      });
    if (typeof window.cmuxAfterPaint === "function") start();
    else addEventListener("DOMContentLoaded", start, { once: true });
  }

  /// Resolves once the transcript's offset and height have held for 30 painted frames.
  const rest = (page: Page) =>
    page.evaluate(async () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      let last = "";
      for (let held = 0, frames = 0; held < 30 && frames < 900; frames += 1) {
        await window.cmuxPaintFrame();
        const now = `${scroller.scrollTop}:${scroller.scrollHeight}`;
        held = now === last ? held + 1 : 0;
        last = now;
      }
    });

  for (const [name] of engines)
    test(`${name}: an opened chat's first frame with rows is its final frame`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
      await installPaintedFrames(page);
      await page.addInitScript(sampleFromStart);
      await page.goto(url());
      await page.getByText(LAST).waitFor();
      await page.evaluate(() => document.fonts.ready);
      await rest(page);
      const { frames, view } = await page.evaluate(() => {
        const w = window as unknown as { __frames: Sample[][]; __stop: () => void };
        w.__stop();
        return { frames: w.__frames, view: { width: innerWidth, height: innerHeight } };
      });
      await page.close();
      expect(frames.length).toBeGreaterThan(0);
      const ids = new Map<string, number>();
      const boxFrames: BoxFrame[] = frames.map(
        (frame) =>
          new Map(
            frame.map((sample) => {
              if (!ids.has(sample.id)) ids.set(sample.id, ids.size + 1);
              return [ids.get(sample.id)!, { box: sample, label: sample.id }] as const;
            }),
          ),
      );
      const shift = scoreBoxFrames(boxFrames, view, { restedAtStart: true });
      // Rows in view at the end that the first frame with rows did not draw: what popped in after it.
      const first = new Set(frames[0]!.map((sample) => sample.id));
      const appeared = frames
        .at(-1)!
        .filter((sample) => !first.has(sample.id))
        .map((sample) => sample.id);
      const moves = shift.moves.map(
        (move) => `${move.label} dy ${Math.round(move.dy)} dx ${Math.round(move.dx)} @${move.frame}`,
      );
      console.log(
        `[${name}] frames ${frames.length} score ${shift.score.toFixed(4)} moves ${moves.length} appeared ${appeared.length}` +
          (moves.length ? `\n  ${moves.slice(0, 20).join("\n  ")}` : "") +
          (appeared.length ? `\n  appeared: ${appeared.join(", ")}` : ""),
      );
      expect({ moves, appeared }).toEqual({ moves: [], appeared: [] });
    });
});
