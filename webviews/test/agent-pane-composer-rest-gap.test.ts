// cmux-web-test-timeout: 240
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The rest gap: the room between the chat's newest row (its last drawn line, or its footer's action
// row when it has one) and the top of the bottom stack (the running tray when it shows, else the
// composer card). Leo, 2026-11-01: "in the next build, will we have more space between composer and
// latest messages? i'd like it... tho maybe not as much as claude code". And: "there's currently some
// oddities where the gap between recent text and composer is bigger than the desired gap ... so
// there's no shift on load and it's just a load".
//
// The gap is REST_GAP (model.ts) in every state the reader sees the chat's end in: at rest, while a
// reply streams, after the composer grows two lines, with the running tray shown, and on every
// painted frame of a chat's load. Before: 16px (the last row's turn gap alone), and a load painted
// frames with another gap before it settled.
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { REST_GAP } from "../src/agent-session/acpmux/model";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-composer-rest-gap.test.ts", async () => {
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
      console.warn(`agent-pane-composer-rest-gap: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("composer rest gap", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "0190a000-0000-7000-8000-0000000000d4";
  let status = "idle";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/sun",
    title: "Retry policy",
    harness: "claude",
    family: "claude",
    status,
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: 6,
    updatedAt: Date.now(),
  });
  const update = (body: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: SESSION, seq: events.length + 1, at: Date.now(), dir, kind, msg };
    events.push(event);
    return event;
  };
  const LAST = "Rest gap ending marker.";
  // History taller than the view, so the chat opens at its latest row over the composer.
  for (let turn = 0; turn < 6; turn++) {
    record("mux", "user_message", { text: `Check step ${turn + 1} of the retry plan`, promptId: `p-${turn}` });
    record("mux", "turn_started", {});
    record(
      "in",
      "agent_message_chunk",
      chunk(
        `Step ${turn + 1}: the client waits longer before each retry, capped at eight seconds, and stops ` +
          "after five attempts. The fetch tests cover a server that fails twice and then answers." +
          (turn === 5 ? ` ${LAST}` : ""),
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
  const WORDS = "the client waits a little longer before each retry and adds random jitter so a crowd does not retry in step".split(
    " ",
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

  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`;
  };

  /// Installed before the page's own scripts. `__restGap()` reads the gap as laid out now: the stack's
  /// top (its first drawn part: the tray, a queue, or the composer card) less the bottom of the newest
  /// row's ink (its text and icons, its action row's included; not the row's own trailing gap). `__frames` holds it
  /// for every painted frame from the first that draws both: read in a ResizeObserver made after the
  /// pane's own observers (which place the rows and the room under them before paint), on a probe
  /// resized in each frame's callbacks, so each read is of the layout that frame paints.
  const sampler = () => {
    const w = window as unknown as {
      __restGap: () => number | undefined;
      __frames: { t: number; gap: number }[];
    };
    /// The bottom of what a row paints: its text's line boxes and its icons, not the boxes around
    /// them (a row's box runs on through its own trailing gap).
    const inkBottom = (row: Element) => {
      let bottom: number | undefined;
      const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT);
      for (let node = walker.nextNode(); node; node = walker.nextNode()) {
        let rects: DOMRect[] = [];
        if (node.nodeType === Node.TEXT_NODE) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(node);
          rects = [...range.getClientRects()];
        } else if (["svg", "img", "canvas"].includes((node as Element).localName)) {
          rects = [(node as Element).getBoundingClientRect()];
        } else continue;
        for (const rect of rects)
          if (rect.width > 0 && rect.height > 0) bottom = Math.max(bottom ?? -Infinity, rect.bottom);
      }
      return bottom;
    };
    /// The top of the bottom stack's first drawn part: the tray, a question, the queue or the card.
    const stackTop = (dock: Element) => {
      const parts = [...dock.children].flatMap((part) =>
        part.classList.contains("acpmux-composer") ? [...part.children] : [part],
      );
      const tops = parts.map((part) => part.getBoundingClientRect()).filter((rect) => rect.height > 0);
      return tops.length ? Math.min(...tops.map((rect) => rect.top)) : undefined;
    };
    w.__restGap = () => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
      const dock = document.querySelector<HTMLElement>(".acpmux-main[data-dock=float] > .acpmux-dock");
      if (!scroller || !dock) return undefined;
      const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")].filter(
        (row) => row.getBoundingClientRect().height > 0,
      );
      if (!rows.length) return undefined;
      const last = rows.reduce((a, b) =>
        Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
      );
      const bottom = inkBottom(last);
      const top = stackTop(dock);
      return bottom === undefined || top === undefined ? undefined : top - bottom;
    };
    w.__frames = [];
    const start = () => {
      if (!document.querySelector(".acpmux-scroll .acpmux-row") || !document.querySelector(".acpmux-dock")) return false;
      const probe = document.createElement("div");
      probe.style.cssText = "position:fixed;left:0;top:0;height:1px;width:1px;pointer-events:none;visibility:hidden";
      document.body.append(probe);
      new ResizeObserver(() => {
        const gap = w.__restGap();
        if (gap !== undefined) w.__frames.push({ t: Math.round(performance.now()), gap: Math.round(gap * 10) / 10 });
      }).observe(probe);
      let wide = false;
      const frame = () => {
        wide = !wide;
        probe.style.width = wide ? "2px" : "1px";
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
      return true;
    };
    // The first rows mount in a React commit whose layout effects make the pane's observers; this
    // observer's callback runs after that commit, so the probe's observer comes after the pane's.
    const mutations = new MutationObserver(() => {
      if (start()) mutations.disconnect();
    });
    mutations.observe(document, { childList: true, subtree: true });
  };

  async function open(name: string) {
    // Each page attaches to the same history: what an earlier page streamed is not part of it.
    events.length = opened;
    status = "idle";
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.addInitScript(sampler);
    await page.goto(url());
    await page.getByText(LAST).waitFor();
    await page.mouse.move(0, 0);
    await rest(page);
    return page;
  }

  /// Resolves once the transcript's offset has held, with nothing in it animating, for 8 frames.
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
      let last = NaN;
      for (let held = 0, frames = 0; held < 8 && frames < 600; frames += 1) {
        await window.cmuxPaintFrame();
        const still = scroller.scrollTop === last && !moving();
        held = still ? held + 1 : 0;
        last = scroller.scrollTop;
      }
    });
  const gap = (page: Page) =>
    page.evaluate(() => (window as unknown as { __restGap: () => number | undefined }).__restGap());
  const frames = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: { t: number; gap: number }[] };
      const taken = w.__frames;
      w.__frames = [];
      return taken;
    });
  /// The frames whose gap is not `want` (within half a pixel, for the fractional line heights).
  const off = (taken: { t: number; gap: number }[], want: number) =>
    taken.filter((frame) => Math.abs(frame.gap - want) > 0.5).map((frame) => `${frame.t}ms: ${frame.gap}px`);

  test.each(engines.map(([name]) => name))("%s: a chat loads with the rest gap on every painted frame", async (name) => {
    const page = await open(name);
    const settled = await gap(page);
    const taken = await frames(page);
    console.log(
      `${name} last row: ` +
        (await page.evaluate(() => {
          const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-scroll .acpmux-row")];
          const last = rows.reduce((a, b) =>
            Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
          );
          const dock = document.querySelector(".acpmux-dock")!.getBoundingClientRect();
          const describe = (node: Element, depth: number): string =>
            depth > 3
              ? ""
              : `${"  ".repeat(depth)}${node.localName}.${[...node.classList].join(".")} ${node.getBoundingClientRect().top.toFixed(1)}-${node.getBoundingClientRect().bottom.toFixed(1)}\n` +
                [...node.children].map((child) => describe(child, depth + 1)).join("");
          return `dock ${dock.top.toFixed(1)}\n${describe(last, 0)}`;
        })),
    );
    console.log(`${name} load: settled ${settled}px over ${taken.length} frames; first ${taken.slice(0, 6).map((f) => f.gap).join(", ")}`);
    expect(taken.length).toBeGreaterThan(0);
    expect(settled).toBeCloseTo(REST_GAP, 0);
    expect(off(taken, settled!)).toEqual([]);
    await page.close();
  });

  test.each(engines.map(([name]) => name))(
    "%s: the rest gap holds while a reply streams, with the tray shown, and after the composer grows",
    async (name) => {
      const page = await open(name);
      // (a) At rest.
      expect(await gap(page)).toBeCloseTo(REST_GAP, 0);
      await frames(page);

      // (b) A reply streams, followed: every frame from its first row keeps the gap.
      status = "running";
      emit("mux", "user_message", { text: "Now write it up", promptId: "p-stream" });
      emit("mux", "turn_started", {});
      changed();
      emit("in", "agent_message_chunk", chunk("Streaming marker. "));
      await page.getByText("Streaming marker.").waitFor();
      await rest(page);
      await frames(page);
      for (let index = 0; index < 40; index++) {
        emit("in", "agent_message_chunk", chunk(`${WORDS.slice(index % 7, (index % 7) + 4).join(" ")} `));
        // fixed-wait: the stream's own cadence, a chunk every frame or two as an agent sends them, is the input under test.
        await Bun.sleep(16 + (index % 3) * 10);
      }
      await rest(page);
      const streamed = await frames(page);
      console.log(`${name} streaming: ${streamed.length} frames, gaps ${[...new Set(streamed.map((f) => f.gap))].join(", ")}`);
      expect(await gap(page)).toBeCloseTo(REST_GAP, 0);
      expect(off(streamed, REST_GAP)).toEqual([]);

      // (d) The running tray comes into the stack over the composer: the rows keep the gap above it.
      emit(
        "in",
        "subagent_spawned",
        update(
          { sessionUpdate: "subagent_spawned" },
          { subagents: [{ id: "a1", parent: null, name: "Reviewer", state: "running" }] },
        ),
      );
      await page.locator(".acpmux-running-tray").waitFor({ timeout: 20_000 });
      await rest(page);
      const trayed = await frames(page);
      const trayTop = await page.evaluate(() => document.querySelector(".acpmux-running-tray")!.getBoundingClientRect().top);
      const card = await page.evaluate(() => document.querySelector(".acpmux-composer-box")!.getBoundingClientRect().top);
      expect(trayTop).toBeLessThan(card);
      console.log(`${name} tray: ${trayed.length} frames, gaps ${[...new Set(trayed.map((f) => f.gap))].join(", ")}`);
      expect(await gap(page)).toBeCloseTo(REST_GAP, 0);
      // The frame the tray first draws in places the rows above it in that same frame.
      expect(off(trayed, REST_GAP)).toEqual([]);

      // (c) The composer grows two lines: the rows keep the gap above the taller stack.
      await page.locator(".acpmux-md").click();
      await page.keyboard.type("Then document the cap");
      for (let line = 0; line < 2; line++) {
        await page.keyboard.press("Shift+Enter");
        await page.keyboard.type(`and line ${line + 2} of the note`);
      }
      await rest(page);
      const grown = await frames(page);
      console.log(`${name} grown: ${grown.length} frames, gaps ${[...new Set(grown.map((f) => f.gap))].join(", ")}`);
      expect(await gap(page)).toBeCloseTo(REST_GAP, 0);
      expect(off(grown, REST_GAP)).toEqual([]);

      emit("mux", "turn_result", { status: "completed" });
      status = "idle";
      changed();
      await page.close();
    },
  );
});
