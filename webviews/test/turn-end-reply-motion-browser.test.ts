// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// The reply's lines that reveal after a turn ends move on the follow motion's curve, never at once
// (Leo's rule: no row moves at once, every change a state transition on the house settle), on every
// route where the end-of-turn fold (turnEndFold.ts) has nothing of its own to play. The real agent pane
// from its dev entry, against a stand-in acpmux daemon (as turn-end-fold-browser.test.ts). The turn's
// last paragraph comes with its end, so it reveals after it:
// - the fold read the rows at the end but cannot play (`playTurnEnd` finds no motion on the thread):
//   the reply never steps more than 75% of its move in one frame, nor past its place and back, the
//   bottom pinned;
// - a turn of words alone (no running line, so no fold): the same;
// - motion off before the end: the end applies at once, and nothing settles on after;
// - the reader scrolled up: the row at the top of their view stays where it is.
// Another chat shown in place of the one that ended is turnEndFold.test.ts's (nothing plays or draws).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("turn-end-reply-motion-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("turn-end-reply-motion-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("turn end reply motion", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000f1";
  const summary = {
    sessionId: SESSION,
    cwd: "/home/dev/net",
    title: "Flaky retry",
    harness: "claude" as string,
    family: "claude" as string,
    status: "idle",
    turnCount: 1,
    updatedAt: Date.now(),
  };
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
  // The chat's earlier turns, so it opens with history above and the view scrolls.
  for (let turn = 0; turn < 6; turn++) {
    record("mux", "user_message", { text: `What does the retry do, part ${turn + 1}?`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `It waits a little longer before each retry and adds a random jitter (part ${turn + 1}).\n\n` +
          "The wait doubles from a quarter second up to the cap, so a flaky network gets time to recover " +
          "while a dead one fails fast enough for the caller to see it.",
      ),
    );
    record("mux", "turn_result", { status: "completed" });
  }
  const opened = events.length;

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary] };
      case "_acpmux/attach":
        return { session: summary, lastSeq: opened, events: events.slice(0, opened) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  type Call = { id: string; title: string; kind: string; command?: string; path?: string };
  const CALLS: Call[] = [
    { id: "t1", title: "git pull -q --ff-only", kind: "execute", command: "git pull -q --ff-only" },
    { id: "t2", title: "Edit src/net/retry.ts", kind: "edit", path: "/home/dev/net/src/net/retry.ts" },
    { id: "t3", title: "bun test test/retry.test.ts", kind: "execute", command: "bun test test/retry.test.ts" },
    {
      id: "t4",
      title: "bun test test/retry.test.ts -t jitter",
      kind: "execute",
      command: "bun test test/retry.test.ts -t jitter",
    },
  ];
  const MORE: Call[] = [
    { id: "t5", title: "Read src/net/backoff.ts", kind: "read", path: "/home/dev/net/src/net/backoff.ts" },
    { id: "t6", title: "bun test test/net", kind: "execute", command: "bun test test/net" },
  ];
  /// After a short aside: before the fix the running turn joined this run and the one above into
  /// one row (turns.ts mergeShortNotes), and the rows the reader had in sight left mid-turn.
  const LAST: Call[] = [
    { id: "t7", title: "bunx tsc --noEmit -p .", kind: "execute", command: "bunx tsc --noEmit -p ." },
    { id: "t8", title: "git status --short", kind: "execute", command: "git status --short" },
  ];
  const started = (call: Call) =>
    update({
      sessionUpdate: "tool_call",
      toolCallId: call.id,
      title: call.title,
      kind: call.kind,
      status: "in_progress",
      ...(call.command && { rawInput: { command: call.command } }),
      ...(call.path && { locations: [{ path: call.path }] }),
      ...(call.kind === "edit" && {
        content: [{ type: "diff", path: call.path, oldText: "const cap = 30;\n", newText: "const cap = 32;\n" }],
      }),
    });
  const finished = (call: Call) =>
    update({
      sessionUpdate: "tool_call_update",
      toolCallId: call.id,
      status: "completed",
      ...(call.kind === "execute" && {
        content: [{ type: "content", content: { type: "text", text: "ok\n" } }],
        rawOutput: { exit_code: 0 },
      }),
    });

  /// The page the turn runs on: each step goes out a painted frame after the one before.
  let runningOn: Page | undefined;
  /// Resolves the turn's end: the test opens its group, then lets the turn end.
  let endTurn: (() => void) | undefined;
  let turnEnded: Promise<void> = Promise.resolve();
  /// Whether the turn runs its calls, or answers with words alone.
  let withTools = true;
  async function run(ws: { send(data: string): void }, params: Record<string, any>, id: number) {
    const send = (event: Event) => ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    const frames = async (n = 3) => {
      for (let frame = 0; frame < n; frame++) await runningOn?.evaluate(() => window.cmuxPaintFrame());
    };
    const text = (params.prompt ?? []).map((block: { text?: string }) => block.text ?? "").join("");
    const ending = new Promise<void>((done) => (endTurn = done));
    send(record("mux", "user_message", { text, promptId: params._meta?.acpmux?.promptId }));
    send(record("mux", "turn_started", {}));
    for (const call of withTools ? CALLS : []) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("The jitter case fails; checking the backoff next.")));
    await frames();
    for (const call of withTools ? MORE : []) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("Now the types:")));
    await frames();
    for (const call of withTools ? LAST : []) {
      send(record("in", "tool_call", started(call)));
      await frames();
      send(record("in", "tool_call_update", finished(call)));
      await frames();
    }
    send(record("in", "agent_message_chunk", chunk("\n\nFixed: the jitter now stays inside the backoff's cap.")));
    await frames();
    await ending;
    // The answer's last paragraph comes with the turn's end: it reveals after it.
    send(record("in", "agent_message_chunk", chunk("\n\nAll of the retry tests pass again.")));
    send(record("mux", "turn_result", { status: "completed" }));
    ws.send(JSON.stringify({ jsonrpc: "2.0", id, result: { stopReason: "end_turn" } }));
  }

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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.method === "session/prompt" && message.id !== undefined) {
            turnEnded = run(ws, message.params ?? {}, message.id);
            return;
          }
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

  /// Where the reply is drawn in the view on each painted frame around the end, the first row drawn
  /// at the view's top (its id and where it is), and whether the fold plays.
  type Sample = { reply: number; topId: string; top: number; folding: boolean; ended: boolean; line: boolean; gap: number };
  type Route = "no-fold" | "words" | "motion-off" | "scrolled-up";
  async function playEnd(route: Route) {
    withTools = route !== "words";
    summary.harness = "claude";
    summary.family = "claude";
    events.length = opened;
    const page = await browser!.newPage({ viewport: { width: 900, height: 520 } });
    await installPaintedFrames(page);
    runningOn = page;
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("random jitter (part 6)").waitFor();
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("Fix the flaky retry test");
    await page.keyboard.press("Enter");
    await page.getByText("Fixed: the jitter now stays", { exact: false }).waitFor();
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    for (let step = 0; step < 4; step++) {
      await page.mouse.wheel(0, route === "scrolled-up" ? -300 : 1_200);
      for (let frame = 0; frame < 6; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    }
    for (let frame = 0; frame < 30; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    if (route === "motion-off") await page.evaluate(() => (document.documentElement.dataset.agentMotion = "off"));
    if (route === "no-fold")
      // The fold reads the rows at the end (it copies the running line), then finds no motion on the
      // thread when it would play: nothing of it plays. Only the fold reads `animate`; the follow
      // motion draws on its own frames.
      await page.evaluate(() => {
        const clone = Node.prototype.cloneNode;
        Node.prototype.cloneNode = function (this: Node, deep?: boolean) {
          const row = this as HTMLElement;
          if (row.dataset?.rowId && row.parentElement?.classList.contains("acpmux-thread"))
            Object.defineProperty(row.parentElement, "animate", { value: undefined, configurable: true });
          return clone.call(this, deep);
        };
      });
    await page.evaluate(() => {
      const samples: Sample[] = [];
      (window as any).replySamples = samples;
      let frames = 0;
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const view = scroller.getBoundingClientRect();
        const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row[data-row-id]")];
        const reply = rows.find((row) => row.textContent?.includes("Fixed: the jitter now stays"));
        const first = rows.find((row) => {
          const at = row.getBoundingClientRect();
          return at.height > 0 && at.bottom > view.top + 1;
        });
        samples.push({
          reply: reply ? reply.getBoundingClientRect().top - view.top : NaN,
          topId: first?.dataset.rowId ?? "",
          top: first ? first.getBoundingClientRect().top - view.top : NaN,
          folding: Boolean(scroller.querySelector("[data-turn-end-folding]")),
          // The answer's last paragraph, which comes with the turn's end, is drawn: the turn ended.
          ended: Boolean(reply?.textContent?.includes("All of the retry tests pass again.")),
          // The turn's running line is drawn (a turn of words alone draws none).
          line: Boolean(scroller.querySelector('.acpmux-row[data-row-id="thinking-live"]')),
          gap: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
        });
        // Until well after the end: the test paints 80 frames after it, so sampling never stops early.
        frames += 1;
        return frames < 400;
      });
    });
    endTurn!();
    await turnEnded;
    // Scrolled up, the reply may be out of the mounted window: the frames after the end are enough.
    if (route !== "scrolled-up") await page.getByText("All of the retry tests pass again.").waitFor();
    for (let frame = 0; frame < 80; frame++) await page.evaluate(() => window.cmuxPaintFrame());
    const samples = (await page.evaluate(() => (window as any).replySamples)) as Sample[];
    return { page, samples };
  }

  /// From `from` on, the reply never steps more than 75% of its whole move in one frame, and never goes
  /// past its place and back (every step one way). A move of a few px is no motion to judge.
  function expectEased(samples: Sample[], from: number, label: string) {
    expect(from).toBeGreaterThan(0);
    const after = samples.slice(from - 1).filter((sample) => Number.isFinite(sample.reply));
    const move = after.at(-1)!.reply - after[0]!.reply;
    const steps = after.slice(1).map((sample, index) => sample.reply - after[index]!.reply);
    console.log(`TURN_END_REPLY ${label} move=${move.toFixed(1)} steps=${JSON.stringify(steps.map(Math.round))}`);
    if (Math.abs(move) > 8) {
      expect(Math.max(...steps.map(Math.abs))).toBeLessThan(Math.abs(move) * 0.75);
      expect(steps.every((step) => Math.sign(step) !== -Math.sign(move) || Math.abs(step) < 1)).toBe(true);
    }
    // The bottom stays pinned once it lands.
    expect(after.at(-1)!.gap).toBeLessThanOrEqual(2);
  }

  test("the fold captured but nothing of it plays: the reply never steps at the end", async () => {
    const { page, samples } = await playEnd("no-fold");
    // Nothing of the fold played.
    expect(samples.some((sample) => sample.folding)).toBe(false);
    // From the frame the running line left: the swap and the paragraph after it.
    expectEased(samples, samples.findIndex((sample) => !sample.line), "no-fold");
    await page.close();
  });

  test("a turn of words alone: the reply never steps at the end", async () => {
    const { page, samples } = await playEnd("words");
    expectEased(samples, samples.findIndex((sample) => sample.ended), "words");
    await page.close();
  });

  test("motion off before the end: the end applies at once, nothing plays or settles on after", async () => {
    const { page, samples } = await playEnd("motion-off");
    expect(samples.some((sample) => sample.folding)).toBe(false);
    const ended = samples.findIndex((sample) => sample.ended);
    expect(ended).toBeGreaterThan(0);
    // At rest within a few frames of the end, and nothing moves after.
    const rest = samples.slice(ended + 4).filter((sample) => Number.isFinite(sample.reply));
    for (const sample of rest) expect(Math.abs(sample.reply - rest.at(-1)!.reply)).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("scrolled up: the row at the top of the view stays where it is through the end", async () => {
    const { page, samples } = await playEnd("scrolled-up");
    const first = samples[0]!;
    expect(first.topId).not.toBe("");
    const same = samples.filter((sample) => sample.topId === first.topId);
    expect(same.length).toBeGreaterThan(samples.length / 2);
    for (const sample of same) expect(Math.abs(sample.top - first.top)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
