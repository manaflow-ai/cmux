// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// While a turn streams, Session Info and the chat header never flicker (Leo, 2026-11-03: "i don't
// want to see flickers of the session info or anything when there's random re-renders EVER",
// cmux#33201). The real pane's dev entry, with Session Info open, takes a long streamed turn from a
// stand-in acpmux: reply tokens, tool calls that start and finish, and usage ticks. On every painted
// frame the test reads each box of Session Info (the panel and its sections) and of the chat header
// (the header and its tools): the element itself, its box, its opacity and visibility, and whether it
// holds text. Over the whole stream none of them is replaced by a new element (a remount), moves,
// blinks (opacity or visibility changes) or paints empty, and no CSS animation or transition starts
// inside either.
//
// Frames are read after they paint (support/paintedFrames.ts). A control at the end shows the sampler
// catches each kind of flicker it looks for. Chromium and WebKit.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-streaming-no-flicker.test.ts", async () => {
  setDefaultTimeout(200_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch (error) {
      console.warn(
        `agent-pane-streaming-no-flicker: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`): ${String(error).slice(0, 400)}`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("streaming keeps Session Info and the header still", () => test("no engine", () => {}));
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
    status: "running",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 3,
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
  const usage = (used: number) => update({ sessionUpdate: "usage_update", size: 400_000, used });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  /// An edit that lands a diff: an earlier turn's files, so Session Info has its changes and outputs
  /// sections before the stream starts.
  const edit = (id: string, file: string, oldText: string | null, newText: string) => {
    record(
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: `Edit ${file}`,
        kind: "edit",
        status: "in_progress",
      }),
    );
    record(
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "diff", path: file, oldText, newText }],
      }),
    );
  };
  for (let turn = 0; turn < 2; turn++) {
    record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record("in", "agent_message_chunk", chunk(`Step ${turn + 1}: the client waits longer before each retry.`));
    if (turn === 0) {
      edit("e1", "/home/dev/sun/src/net/upload.ts", "a\nb\n", "a\nretry\nb\nbackoff\n");
      edit("e2", "/home/dev/sun/src/net/backoff.ts", null, "export const backoff = 2;\n");
      edit("e3", "/home/dev/sun/docs/retries.md", null, "# Retries\n\nCapped at eight seconds.\n");
    }
    record("mux", "turn_result", { status: "completed" });
  }
  record("mux", "user_message", { text: "Find every retry loop and fix the cap", promptId: "p-live" });
  record("mux", "turn_started", {});
  record("in", "agent_message_chunk", chunk("Looking for retry loops.\n\n"));
  record("in", "tool_call", ran("t0"));
  record("in", "usage_update", usage(20_000));
  const opened = events.length;
  const LIVE = "[data-row-id='thinking-live']";

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

  /// Resolves once nothing finite animates on the page for 12 painted frames.
  const rest = (page: Page) =>
    page.evaluate(async () => {
      const moving = () =>
        document
          .getAnimations()
          .some(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let held = 0, frames = 0; held < 12 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        held = moving() ? 0 : held + 1;
      }
    });

  type Report = {
    frames: number;
    keys: string[];
    remounts: string[];
    moves: string[];
    blinks: string[];
    empties: string[];
    animations: string[];
    removed: string[];
  };

  /// Starts reading, after every painted frame, each box of Session Info and the chat header.
  const startSampling = (page: Page) =>
    page.evaluate(() => {
      type Box = { el: number; x: number; y: number; w: number; h: number; o: string; v: string; text: boolean };
      const w = window as unknown as {
        __flicker: { frames: Map<string, Box>[]; animations: string[]; removed: string[]; stop: () => void };
      };
      const ids = new WeakMap<Element, number>();
      let next = 1;
      const idOf = (el: Element) => {
        if (!ids.has(el)) ids.set(el, next++);
        return ids.get(el)!;
      };
      const panel = () => document.querySelector<HTMLElement>("aside.acpmux-session-info");
      const header = () => document.querySelector<HTMLElement>(".acpmux-header");
      const label = (el: Element) => {
        const section = (el as HTMLElement).dataset?.section;
        const classes = (el.getAttribute("class") ?? "").split(/\s+/).filter(Boolean).slice(0, 2).join(".");
        return `${el.tagName.toLowerCase()}${classes ? `.${classes}` : ""}${section ? `[${section}]` : ""}`;
      };
      const inside = (node: Node | null) => !!node && (!!panel()?.contains(node) || !!header()?.contains(node));
      const read = () => {
        const frame = new Map<string, Box>();
        const put = (key: string, el: Element) => {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          frame.set(key, {
            el: idOf(el),
            x: rect.x,
            y: rect.y,
            w: rect.width,
            h: rect.height,
            o: style.opacity,
            v: style.visibility,
            text: (el.textContent ?? "").trim().length > 0,
          });
        };
        const p = panel();
        if (p) {
          put("session-info", p);
          p.querySelectorAll("[data-section]").forEach((el, i) => put(`session-info ${label(el)} #${i}`, el));
        }
        const h = header();
        if (h) {
          put("header", h);
          [...h.children].forEach((el, i) => put(`header ${label(el)} #${i}`, el));
          h.querySelectorAll(".acpmux-header-tool").forEach((el, i) => put(`header ${label(el)} tool #${i}`, el));
        }
        w.__flicker.frames.push(frame);
      };
      const animations: string[] = [];
      const removed: string[] = [];
      // globalThis.Event: the file's own `Event` (the acpmux event, above) would shadow the DOM one here.
      const onAnimation = (event: globalThis.Event) => {
        if (!inside(event.target as Node)) return;
        const name = (event as AnimationEvent).animationName ?? (event as TransitionEvent).propertyName;
        animations.push(`${event.type} ${name} on ${label(event.target as Element)}`);
      };
      for (const kind of ["animationstart", "transitionstart", "transitionrun"])
        document.addEventListener(kind, onAnimation, true);
      const observer = new MutationObserver((records) => {
        for (const record of records)
          for (const node of record.removedNodes)
            if (node.nodeType === 1) removed.push(`${label(node as Element)} from ${label(record.target as Element)}`);
      });
      for (const root of [panel(), header()]) if (root) observer.observe(root, { subtree: true, childList: true });
      let on = true;
      w.__flicker = {
        frames: [],
        animations,
        removed,
        stop: () => {
          on = false;
          for (const record of observer.takeRecords())
            for (const node of record.removedNodes)
              if (node.nodeType === 1)
                removed.push(`${label(node as Element)} from ${label(record.target as Element)}`);
          observer.disconnect();
          for (const kind of ["animationstart", "transitionstart", "transitionrun"])
            document.removeEventListener(kind, onAnimation, true);
        },
      };
      read();
      window.cmuxAfterPaint(() => {
        if (!on) return false;
        read();
        return true;
      });
    });

  const stopSampling = (page: Page): Promise<Report> =>
    page.evaluate(() => {
      type Box = { el: number; x: number; y: number; w: number; h: number; o: string; v: string; text: boolean };
      const w = window as unknown as {
        __flicker: { frames: Map<string, Box>[]; animations: string[]; removed: string[]; stop: () => void };
      };
      w.__flicker.stop();
      const frames = w.__flicker.frames;
      const first = frames[0]!;
      const remounts: string[] = [];
      const moves: string[] = [];
      const blinks: string[] = [];
      const empties: string[] = [];
      for (const [key, start] of first) {
        let lastEl = start.el;
        for (let i = 1; i < frames.length; i++) {
          const now = frames[i]!.get(key);
          if (!now) {
            empties.push(`${key} gone at frame ${i}`);
            break;
          }
          if (now.el !== lastEl) {
            remounts.push(`${key} at frame ${i}`);
            lastEl = now.el;
          }
          const moved = Math.max(
            Math.abs(now.x - start.x),
            Math.abs(now.y - start.y),
            Math.abs(now.w - start.w),
            Math.abs(now.h - start.h),
          );
          if (moved > 0.5) {
            moves.push(
              `${key} at frame ${i}: ${[start.x, start.y, start.w, start.h].map(Math.round).join(",")} -> ${[now.x, now.y, now.w, now.h].map(Math.round).join(",")}`,
            );
            break;
          }
          if (now.o !== start.o || now.v !== start.v) {
            blinks.push(`${key} at frame ${i}: opacity ${start.o} -> ${now.o}, visibility ${start.v} -> ${now.v}`);
            break;
          }
          if (start.text && !now.text) {
            empties.push(`${key} empty at frame ${i}`);
            break;
          }
        }
      }
      return {
        frames: frames.length,
        keys: [...first.keys()],
        remounts,
        moves,
        blinks,
        empties,
        animations: [...new Set(w.__flicker.animations)],
        removed: [...new Set(w.__flicker.removed)],
      };
    });

  test.each(engines.map(([name]) => name))(
    "%s: a long streamed turn never remounts, moves, blinks or replays an animation in Session Info or the header",
    async (name) => {
      events.length = opened;
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1400, height: 820 } });
      try {
        await installPaintedFrames(page);
        await page.goto(url());
        await page.locator(LIVE).waitFor();
        await page.mouse.move(0, 0);
        // Session Info on (Debug Settings `agent.sessionInfo`), as the header state carries it.
        await page.evaluate(() =>
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
        );
        const toggle = page.locator("button.acpmux-session-info-toggle").first();
        await toggle.waitFor({ timeout: 10_000 });
        if ((await toggle.getAttribute("aria-pressed")) !== "true") await toggle.click({ force: true });
        await page.waitForFunction(
          () => document.querySelector("aside.acpmux-session-info")?.getAttribute("data-presence") === "shown",
        );
        await page.locator(".acpmux-header").waitFor();
        // The first streamed update draws what a streaming chat shows; then the panel's enter settles.
        emit("in", "agent_message_chunk", chunk("Starting. "));
        await rest(page);
        await startSampling(page);
        const paint = (frames: number) =>
          page.evaluate(async (count) => {
            for (let frame = 0; frame < count; frame++) await window.cmuxPaintFrame();
          }, frames);
        let used = 20_000;
        for (let step = 1; step <= 12; step++) {
          for (const word of `Call site ${step} retries on every error, so the cap applies here too. `.split(" ")) {
            emit("in", "agent_message_chunk", chunk(`${word} `));
            await paint(1);
          }
          emit("in", "tool_call", ran(`t${step}`, "in_progress"));
          await paint(2);
          used += 380;
          emit("in", "usage_update", usage(used));
          changed();
          await paint(2);
          emit(
            "in",
            "tool_call_update",
            update({ sessionUpdate: "tool_call_update", toolCallId: `t${step}`, status: "completed" }),
          );
          await paint(2);
        }
        await paint(20);
        const report = await stopSampling(page);
        console.log(`${name} streaming flicker:`, JSON.stringify(report));
        expect(report.keys).toContain("session-info");
        expect(report.keys).toContain("header");
        expect(report.keys.some((key) => key.startsWith("session-info ") && key.includes("["))).toBe(true);
        expect(report.frames).toBeGreaterThan(100);
        expect(report.remounts).toEqual([]);
        expect(report.removed).toEqual([]);
        expect(report.moves).toEqual([]);
        expect(report.blinks).toEqual([]);
        expect(report.empties).toEqual([]);
        expect(report.animations).toEqual([]);

        // The sampler sees each kind of flicker: a section replaced by a copy (a remount), the header
        // dimmed for one frame (a blink) and a CSS animation started on a header tool.
        await startSampling(page);
        await page.evaluate(async () => {
          const section = document.querySelector("aside.acpmux-session-info [data-section]")!;
          section.replaceWith(section.cloneNode(true));
          await window.cmuxPaintFrame();
          const header = document.querySelector<HTMLElement>(".acpmux-header")!;
          header.style.opacity = "0.5";
          await window.cmuxPaintFrame();
          header.style.opacity = "";
          const style = document.createElement("style");
          style.textContent = "@keyframes flicker-probe{from{opacity:.99}to{opacity:1}}";
          document.head.append(style);
          document.querySelector<HTMLElement>(".acpmux-header-tool")!.style.animation = "flicker-probe 50ms";
          for (let frame = 0; frame < 6; frame++) await window.cmuxPaintFrame();
        });
        const control = await stopSampling(page);
        console.log(`${name} sampler control:`, JSON.stringify({ ...control, keys: undefined }));
        expect(control.remounts.length).toBeGreaterThan(0);
        expect(control.removed.length).toBeGreaterThan(0);
        expect(control.blinks.some((blink) => blink.startsWith("header at frame"))).toBe(true);
        expect(control.animations.some((animation) => animation.includes("flicker-probe"))).toBe(true);
      } finally {
        await page.close();
      }
    },
  );
});
