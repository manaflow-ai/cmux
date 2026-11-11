// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat shown again draws what came while it was away in place (Leo, 2026-11-11: "we just ran into
// this CRAZY display animation where a new message from you seemed to come down from the heavens...
// austin was navigating between workspaces and there was existing tool calls adn messages and a sliver
// of space at the bottom that the newest few lines started from the top").
//
// Each tab's page stays alive while another workspace shows; the host hides it (`visibilityState`)
// and draws no frames for it, so `requestAnimationFrame` waits. Here the page is hidden the same way:
// visibility reads hidden, `visibilitychange` fires, and frame callbacks queue until it shows again;
// or occluded, as a workspace switch leaves a tab's view: no frames, though the page reads visible
// and its timers still run.
// While a turn streams into the followed chat, the page hides; two tool calls, a thought and more of
// the reply land; the page shows again. On every frame from the first one back, each row on screen
// must be drawn where it rests (no row moves), so nothing comes down from above and no gap opens at
// the bottom. Chromium and WebKit, at rest and with a busy main thread.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon (as agent-pane-stream-row-overlap.test.ts).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-reveal-in-place.test.ts", async () => {
  setDefaultTimeout(540_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-reveal-in-place: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("shown again in place", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000e3";
  let status = "idle";
  let queued = 0;
  /// The other agents' messages acpmux holds for the next turn, as its summary lists them.
  let queue: Record<string, unknown>[] = [];
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Shown again",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued,
    queue,
    turnCount: 1,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const thought = (text: string) => update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  let events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  let opened = 0;
  /// History that fills the view, so the chat opens at its latest line.
  const history = () => {
    events = [];
    status = "idle";
    queued = 0;
    queue = [];
    record("mux", "user_message", { text: "Watch the revert", promptId: "p-0" });
    record("mux", "turn_started", {});
    for (let index = 0; index < 14; index++)
      record(
        "in",
        "agent_message_chunk",
        chunk(`Earlier paragraph ${index}. Words that fill the view with the chat's history.\n\n`),
      );
    record("mux", "turn_result", { status: "completed" });
    opened = events.length;
  };
  history();

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
        params: { sessionId: SESSION, session: summary(), kind: "queue", seq: events.length },
      }),
    );
  const toolCall = (id: string, command: string, title = command) =>
    emit(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title,
        kind: "execute",
        status: "in_progress",
        rawInput: { command, description: title },
      }),
    );
  const toolDone = (id: string, text = "ok\n") =>
    emit(
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text } }],
        rawOutput: { exit_code: 0 },
      }),
    );
  const WORDS =
    "the high risk hold waits on a person and the checks that are still red belong to the main branch so the helper reruns them".split(
      " ",
    );
  // fixed-wait: the stream's own cadence, bursts a frame or two apart as an agent sends them, is the input under test.
  const pause = (ms: number) => Bun.sleep(ms);
  async function words(count: number) {
    for (let index = 0; index < count; index++) {
      const text = WORDS.slice(index % 9, (index % 9) + 4).join(" ");
      emit("in", "agent_message_chunk", chunk(`${text}${index % 16 === 15 ? ".\n\n" : " "}`));
      await pause(14 + (index % 3) * 9);
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

  const lag = (page: Page, busy: number, every: number) =>
    page.evaluate(
      ([busy, every]) => {
        window.setInterval(() => {
          const until = performance.now() + busy;
          while (performance.now() < until) {
            /* busy */
          }
        }, every);
      },
      [busy, every] as const,
    );

  /// Hides the page as the host does: visibility reads hidden, `visibilitychange` fires, and frame
  /// callbacks wait (the host draws no frames for a hidden page) until `show` runs them.
  const installHiding = (page: Page) =>
    page.addInitScript(() => {
      const w = window as unknown as {
        __hidden: boolean;
        __queued: FrameRequestCallback[];
        __raf: typeof requestAnimationFrame;
        __occluded: boolean;
        __hide: (occluded?: boolean, suspend?: boolean) => void;
        __show: () => void;
      };
      w.__hidden = false;
      w.__queued = [];
      w.__raf = window.requestAnimationFrame.bind(window);
      let ids = 1_000_000;
      const waiting = new Map<number, FrameRequestCallback>();
      window.requestAnimationFrame = (callback) => {
        if (!w.__hidden) return w.__raf(callback);
        ids += 1;
        waiting.set(ids, callback);
        return ids;
      };
      const cancel = window.cancelAnimationFrame.bind(window);
      window.cancelAnimationFrame = (id) => {
        if (!waiting.delete(id)) cancel(id);
      };
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => (w.__hidden && !w.__occluded ? "hidden" : "visible"),
      });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => w.__hidden && !w.__occluded });
      w.__occluded = false;
      w.__hide = (occluded = false, suspend = false) => {
        (w as unknown as { __suspend: boolean }).__suspend = suspend;
        w.__hidden = true;
        // Occluded (another workspace's view over it): no frames, but the page still reads visible
        // and its timers run, so its snapshots land on the 50 ms fallback (direct.ts `nextFrame`).
        w.__occluded = occluded;
        if (!occluded) document.dispatchEvent(new Event("visibilitychange"));
      };
      // WebKit draws nothing for a hidden page: no frames, and so no ResizeObserver delivery (it runs
      // in a frame's rendering steps), and its timers run at most about once a second. Suspended
      // (`__suspend`), the page is hidden that way too: an observer's deliveries while hidden are
      // dropped and it observes its targets again on show, so it measures them on the first frame back.
      const RealObserver = window.ResizeObserver;
      const observers = new Set<{
        real: ResizeObserver;
        targets: Map<Element, ResizeObserverOptions | undefined>;
        missed: boolean;
      }>();
      (w as unknown as { __suspend: boolean }).__suspend = false;
      const suspended = () => w.__hidden && (w as unknown as { __suspend: boolean }).__suspend;
      window.ResizeObserver = class {
        #own: { real: ResizeObserver; targets: Map<Element, ResizeObserverOptions | undefined>; missed: boolean };
        constructor(callback: ResizeObserverCallback) {
          const own = {
            targets: new Map<Element, ResizeObserverOptions | undefined>(),
            missed: false,
            real: undefined as unknown as ResizeObserver,
          };
          own.real = new RealObserver((entries, observer) => {
            if (suspended()) {
              own.missed = true;
              return;
            }
            callback(entries, this as unknown as ResizeObserver);
            void observer;
          });
          this.#own = own;
          observers.add(own);
        }
        observe(target: Element, options?: ResizeObserverOptions) {
          this.#own.targets.set(target, options);
          this.#own.real.observe(target, options);
        }
        unobserve(target: Element) {
          this.#own.targets.delete(target);
          this.#own.real.unobserve(target);
        }
        disconnect() {
          this.#own.targets.clear();
          this.#own.real.disconnect();
          observers.delete(this.#own);
        }
      } as unknown as typeof ResizeObserver;
      const realTimeout = window.setTimeout.bind(window);
      window.setTimeout = ((handler: TimerHandler, ms?: number, ...rest: unknown[]) =>
        realTimeout(handler, suspended() ? Math.max(ms ?? 0, 1000) : ms, ...rest)) as typeof setTimeout;
      w.__show = () => {
        const wasSuspended = suspended();
        w.__hidden = false;
        if (!w.__occluded) document.dispatchEvent(new Event("visibilitychange"));
        w.__occluded = false;
        if (wasSuspended)
          for (const own of observers)
            if (own.missed) {
              own.missed = false;
              for (const [target, options] of own.targets) {
                own.real.unobserve(target);
                own.real.observe(target, options);
              }
            }
        // The frames asked for while hidden run in the first frame back, as the host draws it.
        const due = [...waiting.values()];
        waiting.clear();
        w.__raf((now) => {
          // The workspace shows again at the size it has now (the window or the sidebar changed while
          // it was away): the page lays out at it in the first frame back, in the same frame that
          // draws what it held, before any ResizeObserver or scroll event can report it.
          for (const callback of due) callback(now);
        });
      };
    });

  async function open(name: string) {
    history();
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installHiding(page);
    if (process.env.REVEAL_DEBUG)
      page.on("console", (message) => {
        if (message.text().startsWith("DBG")) console.log(`PAGE ${message.text().slice(0, 1500)}`);
      });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.getByText("Earlier paragraph 13.").waitFor();
    // fixed-wait: the opened chat settles (its fades end) before the turn under test.
    await page.waitForTimeout(600);
    return page;
  }

  /// What the reader saw from the switch back until the chat rested.
  type Seen = {
    frames: number;
    /// The most any row on screen came down (moved toward the bottom) over consecutive frames, px:
    /// a followed chat only moves its rows up, so anything here came down from above.
    fell: number;
    worst: string;
    /// The first frame back: how far each row on screen is drawn from where it lies on the next
    /// frame that draws the same rows at rest, the most of them, px.
    firstOff: number;
    gapFirst: number;
    gapRest: number;
    trace: string[];
  };

  /// More than a line and a half down is a block coming from above, never a row settling.
  const FELL_PX = 32;
  type Away = "hidden" | "suspended" | "occluded";
  type Resize = "same" | "nudge" | "taller" | "shorter";
  const cases: { away: Away; resize: Resize; lagging: boolean; after: boolean }[] = [];
  for (const away of ["hidden", "suspended", "occluded"] as const)
    for (const resize of ["same", "nudge", "taller", "shorter"] as const)
      for (const lagging of [false, true]) cases.push({ away, resize, lagging, after: true });

  const only = process.env.REVEAL_ONLY ? new RegExp(process.env.REVEAL_ONLY) : undefined;
  for (const [name] of engines)
    for (const { away, resize, lagging, after } of cases)
      if (!only || only.test(`${name} ${away} ${resize}${lagging ? " lagging" : ""}`))
        test(`${name}, ${away}, ${resize}${lagging ? ", lagging" : ""}: rows never come down after a switch back`, async () => {
          const page = await open(name);
          if (lagging) await lag(page, 40, 70);
          // A turn streams into the followed chat.
          status = "running";
          changed();
          emit("mux", "user_message", { text: "Check the nightly and the revert", promptId: "p-away" });
          emit("mux", "turn_started", {});
          await pause(200);
          emit("in", "agent_message_chunk", chunk("Looking at both now. "));
          await words(24);
          // The reader switches to another workspace while it streams.
          await page.evaluate(
            ([occluded, suspend]) =>
              (window as unknown as { __hide: (occluded: boolean, suspend: boolean) => void }).__hide(
                occluded,
                suspend,
              ),
            [away === "occluded", away === "suspended"] as const,
          );
          for (let index = 0; index < 2; index++) {
            toolCall(`away-${index}`, `gh run view 4295${index} --log-failed`, `Read the failed run ${index}`);
            await pause(60);
            toolDone(`away-${index}`);
            await pause(60);
          }
          emit("in", "agent_thought_chunk", thought("Weighing what failed. "));
          await pause(80);
          emit("in", "agent_message_chunk", chunk("\n\nBoth runs failed on the same step. "));
          await words(40);
          // fixed-wait: the hidden page's commits land (its placement passes run without frames).
          await pause(1200);
          // The window or the sidebar changed while the chat was away: the host sizes the page while it
          // is still away, and the page draws nothing at the new size until it shows (its resize is
          // heard in the first frame back, after what it held draws; WindowRootView.show).
          if (resize !== "same") {
            await page.evaluate(() => ((window as unknown as { __suspend: boolean }).__suspend = true));
            await page.setViewportSize({ width: 900, height: { nudge: 643, taller: 760, shorter: 560 }[resize] });
            // fixed-wait: the new size reaches the page before it shows.
            await pause(200);
          }
          // More of the reply lands just before the reader comes back.
          await words(4);
          await pause(100);
          // The workspace shows again at another size (the window or sidebar changed while away): the
          // host sizes the page, then shows it (WindowRootView.show).
          const follow = () =>
            page.evaluate(async () => {
              const { followTrace } = (await import(/* @vite-ignore */ `${location.origin}/followTrace.ts`)) as {
                followTrace: { snapshot(): Record<string, unknown> };
              };
              const snap = followTrace.snapshot();
              return JSON.stringify({
                ...snap,
                stops: (snap.stops as unknown[]).slice(-3),
                arms: (snap.arms as unknown[]).slice(-3),
              });
            });
          const followBefore = process.env.REVEAL_DEBUG ? await follow() : "";
          const following = () =>
            page.evaluate(async () => {
              const { followTrace } = (await import(/* @vite-ignore */ `${location.origin}/followTrace.ts`)) as {
                followTrace: { snapshot(): { following: boolean } };
              };
              return followTrace.snapshot().following;
            });
          // REVEAL_FRAMES_DIR (a PR's before and after): Chromium's own frames from the show on, as drawn.
          const framesDir = process.env.REVEAL_FRAMES_DIR;
          const shots: { at: number; data: string }[] = [];
          const cdp =
            framesDir && name === "chromium" && !lagging ? await page.context().newCDPSession(page) : undefined;
          if (cdp) {
            cdp.on(
              "Page.screencastFrame",
              (frame: { data: string; sessionId: number; metadata: { timestamp?: number } }) => {
                shots.push({ at: frame.metadata.timestamp ?? 0, data: frame.data });
                void cdp.send("Page.screencastFrameAck", { sessionId: frame.sessionId }).catch(() => {});
              },
            );
            await cdp.send("Page.startScreencast", { format: "png", everyNthFrame: 1 });
          }
          // Back to the chat: every frame from the first one back records each row on screen.
          await page.evaluate(() => {
            const w = window as unknown as {
              __raf: typeof requestAnimationFrame;
              __show: () => void;
              __frames: { tops: [string, number][]; gap: number; scroll: number; tr: string }[];
              __recording: boolean;
            };
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const thread = scroller.querySelector<HTMLElement>(".acpmux-thread");
            const rowsOf = () => [
              ...scroller.querySelectorAll<HTMLElement>(".acpmux-thread > .acpmux-row[data-row-id]"),
            ];
            w.__frames = [];
            w.__recording = true;
            const sample = () => {
              const view = scroller.getBoundingClientRect();
              const tops: [string, number][] = [];
              let low = Number.NEGATIVE_INFINITY;
              for (const row of rowsOf()) {
                const rect = row.getBoundingClientRect();
                if (rect.height > 0.5 && rect.bottom > view.top && rect.top < view.bottom)
                  tops.push([row.dataset.rowId!, rect.top]);
                if (rect.height > 0.5) low = Math.max(low, rect.bottom);
              }
              const dock = document.querySelector<HTMLElement>(".acpmux-composer-box, .acpmux-dock");
              const floor = dock?.getBoundingClientRect().top ?? view.bottom;
              w.__frames.push({
                tops,
                gap: floor - low,
                scroll: scroller.scrollTop,
                tr: thread?.style.translate || "-",
              });
            };
            w.__show();
            const loop = () =>
              w.__raf(() => {
                sample();
                if (w.__recording) loop();
              });
            loop();
          });
          // The turn goes on after the reader is back: a call, then more of the reply, as Austin saw.
          if (after) {
            await pause(300);
            toolCall("back-0", "bun test", "Run the tests");
            await pause(120);
            toolDone("back-0");
            await pause(60);
            emit("in", "agent_message_chunk", chunk("\n\nThe tests pass now. "));
            await words(30);
          }
          // fixed-wait: whatever still moves comes to rest.
          await pause(1200);
          const debug = Boolean(process.env.REVEAL_DEBUG);
          const seen = (await page.evaluate((debug) => {
            const w = window as unknown as {
              __frames: { tops: [string, number][]; gap: number; scroll: number; tr: string }[];
              __recording: boolean;
            };
            w.__recording = false;
            const frames = w.__frames.map((frame) => ({ ...frame, map: new Map(frame.tops) }));
            // How far each row came down over a run of frames in which it only came down.
            let fell = 0;
            let worst = "";
            const run = new Map<string, number>();
            for (let index = 1; index < frames.length; index++) {
              const before = frames[index - 1]!.map;
              for (const [id, top] of frames[index]!.map) {
                // The live line under a row that came glides down to make its room (tailGlide.ts): by design.
                if (id === "thinking-live") continue;
                const was = before.get(id);
                if (was === undefined) {
                  run.delete(id);
                  continue;
                }
                const down = top - was;
                const total = down > 0.5 ? (run.get(id) ?? 0) + down : 0;
                run.set(id, total);
                if (total > fell) {
                  fell = total;
                  worst = `frame ${index + 1}: ${id} came down ${Math.round(total)} px (to ${Math.round(top)})`;
                }
              }
            }
            // The first frame back against the next frame with the same rows and nothing moving.
            const first = frames[0]!;
            let firstOff = 0;
            const restAt = frames.findIndex(
              (frame, index) =>
                index > 0 &&
                frame.tr === "-" &&
                frame.map.size === first.map.size &&
                [...first.map.keys()].every((id) => frame.map.has(id)) &&
                [...frame.map].every(
                  ([id, top]) => Math.abs((frames[index - 1]!.map.get(id) ?? Number.NaN) - top) < 0.5,
                ),
            );
            if (restAt > 0)
              for (const [id, top] of first.map)
                firstOff = Math.max(firstOff, Math.abs(top - frames[restAt]!.map.get(id)!));
            const trace = frames
              .slice(0, debug ? 40 : 8)
              .map(
                (frame, index) =>
                  `f${index + 1} scroll=${Math.round(frame.scroll)} tr=${frame.tr} gap=${Math.round(frame.gap)} ${frame.tops.map(([id, top]) => `${id.slice(-8)}@${Math.round(top)}`).join(" ")}`,
              );
            return {
              frames: frames.length,
              fell: Math.round(fell * 10) / 10,
              worst,
              firstOff: Math.round(firstOff * 10) / 10,
              gapFirst: Math.round(first.gap),
              gapRest: Math.round(frames.at(-1)!.gap),
              trace,
            };
          }, debug)) as Seen;
          console.log(`REVEAL_REPORT ${JSON.stringify({ engine: name, away, resize, lagging, ...seen })}`);
          if (process.env.REVEAL_DEBUG) console.log(`REVEAL_FOLLOW before=${followBefore} after=${await follow()}`);
          const stillFollowing = await following();
          if (cdp && framesDir) {
            await cdp.send("Page.stopScreencast").catch(() => {});
            const dir = path.join(framesDir, `${name}-${away}-${resize}`);
            mkdirSync(dir, { recursive: true });
            const start = shots[0]?.at ?? 0;
            shots
              .slice(0, 40)
              .forEach((shot, index) =>
                writeFileSync(
                  path.join(
                    dir,
                    `frame-${String(index).padStart(3, "0")}-${Math.round((shot.at - start) * 1000)}ms.png`,
                  ),
                  Buffer.from(shot.data, "base64"),
                ),
              );
          }
          status = "idle";
          emit("mux", "turn_result", { status: "completed" });
          changed();
          await page.close();
          expect(seen.frames).toBeGreaterThan(30);
          // The reader never scrolled: the chat still follows its latest row, the newest line over the
          // composer, not under it behind Jump to latest.
          expect({ following: stillFollowing, gapRest: seen.gapRest >= 0 }).toEqual({ following: true, gapRest: true });
          // A followed chat only moves its rows up: nothing on screen comes down from above.
          // (A streamed row may settle a few px as the follow chase lands, as it does with no switch at
          // all; what came down after a switch was 80 to 150 px, a whole block.)
          expect({ fell: seen.fell > FELL_PX ? seen.fell : 0, worst: seen.fell > FELL_PX ? seen.worst : "" }).toEqual({
            fell: 0,
            worst: "",
          });
          // The first frame back draws the rows where they rest.
          expect(seen.firstOff).toBeLessThanOrEqual(0.5);
        });
});
