// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A followed chat stays still at its bottom while a reply streams (Leo, 2026-10-20: "the transcript
// jumps up and down instead of staying pinned"). The reply streams a few words at a time, a tool call
// opens the turn's working line over the reply, a queued prompt's card comes into the bottom stack
// and goes, and a queued prompt is sent as the next turn. On every painted frame the text the reader
// is reading only moves up, and the view rests at the latest line. Sampled per frame on base
// 6fe9ab414ee: the reply dropped 35px and slid back when the tool call came (the glide moved the
// whole thread by what grew, also above the reply), and the view dropped 54px when the queue card
// left the stack, then rose again as its prompt arrived.
// A queued prompt deleted from the queue never comes in as a row: the view goes back to its end at
// once, with no card-high gap held under the last row (held for a second after #22858).
// A reader who scrolls up while it streams is left where they scrolled: in WebKit the wheel moves the
// offset a frame before its scroll event, and a snapshot landing between them put the view back at
// the latest row (on base, 3 runs in 6).
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon. Both engines the app uses (WebKit draws the pane in cmux NEXT); one not installed skips.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
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

  async function open(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Opening paragraph 19.").waitFor();
    await page.waitForTimeout(500);
    return page;
  }

  /// One frame: where the row holding `marker` is drawn (transforms included).
  type Frame = { t: number; marker?: number };
  /// Samples every frame, from its animation frame callback, until `stop`.
  const sample = (page: Page, marker: string) =>
    page.evaluate((marker) => {
      const w = window as unknown as { __frames: Frame[]; __stop: boolean };
      w.__frames = [];
      w.__stop = false;
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const tick = () => {
        if (w.__stop) return;
        const row = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].find((each) =>
          each.textContent?.includes(marker),
        );
        w.__frames.push({ t: Math.round(performance.now()), marker: row?.getBoundingClientRect().top });
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, marker);
  const stop = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: Frame[]; __stop: boolean };
      w.__stop = true;
      return w.__frames;
    });
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
          const tick = (now: number) => {
            if (scroller.scrollTop !== last) [last, since] = [scroller.scrollTop, now];
            if (now - since >= 200) resolve(last);
            else requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        }),
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
      await page.waitForTimeout(800);
      const frames = await stop(page);
      expect({ drops: drops(frames), atEnd: (await fromEnd(page)) <= 4 }).toEqual({ drops: [], atEnd: true });
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
      await page.waitForTimeout(800);
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
      await page.waitForTimeout(600);
      expect({ kept: Math.abs((await scrollTop(page)) - left) <= 1, behind: (await fromEnd(page)) > 200 }).toEqual({
        kept: true,
        behind: true,
      });
      await page.close();
    },
  );

  /// How far the last row sits above the bottom stack's top, once the transcript is at rest. A new row
  /// rises in (cv-enter) and growth glides in (GLIDE_MS); a read mid-way put the row up to 41px low
  /// in Chromium on a loaded machine, though scrollTop never moved. Infinite ones (a spinner) aside.
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
      await page.waitForTimeout(400);
      const resting = await gapAbove(page);
      unqueue("queue_removed", `q-${turn}`);
      await page.locator(".acpmux-queued").waitFor({ state: "detached" });
      await page.waitForTimeout(600);
      const gap = await gapAbove(page);
      toolDone(`t-${turn}`);
      endTurn();
      // The last row rests on the stack's top again, a card's height lower, well before a second.
      expect({ gap: Math.abs(gap - resting) <= 4, atEnd: (await fromEnd(page)) <= 4 }).toEqual({
        gap: true,
        atEnd: true,
      });
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
      await page.waitForTimeout(400);
      const resting = await gapAbove(page);
      enqueue(`q-${turn}`, "never mind this one");
      await page.locator(".acpmux-queued").waitFor();
      await page.waitForTimeout(300);
      if (order === "queue") {
        // acpmux's queue update can come before its `queue_removed` record.
        queue = [];
        changed();
        await page.waitForTimeout(30);
        emit("mux", "queue_removed", { promptId: `q-${turn}` });
      } else unqueue("queue_removed", `q-${turn}`);
      await page.locator(".acpmux-queued").waitFor({ state: "detached" });
      await page.waitForTimeout(300);
      expect({ gap: Math.abs((await gapAbove(page)) - resting) <= 4, atEnd: (await fromEnd(page)) <= 4 }).toEqual({
        gap: true,
        atEnd: true,
      });
      await page.close();
    },
  );
});
