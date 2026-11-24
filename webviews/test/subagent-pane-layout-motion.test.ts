// l10n-allow-file: test fixture prompts, replies and subagent names, not shipped UI.
// Leo, 2026-11-19, of a subagent's chat: "the composer is kinda odd looking for subagents" and "and
// it layout shifts too". This drives what he did, in the real pane (its dev entry and browser host,
// JSON-RPC to a stand-in acpmux daemon; the app's `subagent:` reveal is the page bridge's
// `revealTurn`), and samples every frame:
//   1. the chat opens, then its subagent opens in the pane (the subagent's composer mounts);
//   2. a reply streams into the chat while the subagent shows;
//   3. "Subagent of" goes back to the chat, and the subagent opens again (chat <-> subagent);
//   4. a prompt is typed in the subagent's composer until it wraps.
// Each frame records the composer box, the "Subagent of" pill and the transcript's last row. A box
// counts as moved when its edge is more than half a pixel (the layout-motion contract's slack,
// schemas/layout-motion) from where it last stood; the composer is compared across the switch, as
// the person sees one composer at the pane's foot, and the pill across each time it shows. The
// only declared move is the composer's growth while a typed line wraps (`composer-growth`), so in
// every other step the composer and the pill move 0 px. Each run prints one `LAYOUT-MOTION
// subagent` line per step with the largest move of each, the numbers of the before/after table.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("subagent-pane-layout-motion.test.ts", async () => {
  setDefaultTimeout(180_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e7";
  const START = Date.now() - 60_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  let socket: { send(data: string): void } | undefined;
  /// An acpmux record: in the log a later attach replays, and sent live to the attached page.
  const record = (dir: string, kind: string, msg: Record<string, unknown>) => {
    const event = { sessionId: CHAT, seq: events.length + 1, at: START + events.length * 1000, dir, kind, msg };
    events.push(event);
    socket?.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  const chunk = (text: string) =>
    record(
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
    );
  record("mux", "user_message", { text: "Rebase the branch and have an agent land it" });
  record("mux", "turn_started", {});
  record(
    "in",
    "subagent_spawned",
    update(
      { sessionUpdate: "subagent_spawned" },
      {
        subagents: [
          {
            id: "a1",
            parent: null,
            name: "Rebase cmux#46667 and land it",
            task: "Rebase cmux#46667 and land it",
            state: "running",
            startedAt: START + 3000,
            agentId: "a39e817af38ddf5e7",
          },
        ],
      },
    ),
  );
  chunk("The lander is on it.");
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "claude-sr2-coord-old",
    harness: "claude",
    family: "claude",
    status: "working",
    turnCount: 1,
    steering: true,
    updatedAt: START,
  };
  const answer = (method: string): unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session: { ...session, lastSeq: events.length }, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };

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
          socket = ws;
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Rect = { top: number; bottom: number; left: number; right: number };
  type Frame = {
    at: "painted" | "callbacks";
    step: string;
    composer?: Rect;
    subagent: boolean;
    pill?: Rect;
    row?: { id: string; rect: Rect };
  };
  /// Starts sampling every frame into `window.__frames`, each tagged with `window.__step`, twice: as
  /// the frame painted it (`cmuxAfterPaint`, support/paintedFrames.ts) and as the frame's own
  /// callbacks see it (`callbacks`: before the frame's layout and ResizeObservers, where the follow
  /// chase and the pinned live line read the rows). A transcript shown again stands in its final
  /// place for both: a state the callbacks read and an observer then corrects is a frame in which
  /// everything that draws per frame drew from rows that were not where they end up.
  const sample = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as {
        __frames: unknown[];
        __step: string;
        __stop?: () => void;
        cmuxAfterPaint: (read: () => boolean | void, drive?: () => void) => () => void;
      };
      w.__frames = [];
      w.__step = "open-subagent";
      const rect = (node: Element | null | undefined) => {
        if (!node) return undefined;
        const r = node.getBoundingClientRect();
        return r.width || r.height ? { top: r.top, bottom: r.bottom, left: r.left, right: r.right } : undefined;
      };
      const read = (at: "painted" | "callbacks") => {
        const rows = document.querySelectorAll("[data-row-id]");
        const last = rows[rows.length - 1];
        w.__frames.push({
          at,
          step: w.__step,
          composer: rect(document.querySelector(".acpmux-composer-box")),
          subagent: Boolean(document.querySelector("form.acpmux-composer[data-composer-relay]")),
          pill: rect(document.querySelector(".cv-subagent-of")),
          row: last ? { id: last.getAttribute("data-row-id") ?? "", rect: rect(last) } : undefined,
        });
      };
      w.__stop = w.cmuxAfterPaint(
        () => read("painted"),
        () => read("callbacks"),
      );
    });
  const step = (page: Page, name: string) =>
    page.evaluate((name) => ((window as unknown as { __step: string }).__step = name), name);
  const frames = (page: Page) =>
    page.evaluate(() => {
      const w = window as unknown as { __frames: unknown[]; __stop?: () => void };
      w.__stop?.();
      return w.__frames;
    }) as Promise<Frame[]>;
  /// Waits `count` frames in the page (an event per frame, not a timer).
  const settle = (page: Page, count = 20) =>
    page.evaluate(
      (count) =>
        new Promise<void>((done) => {
          let left = count;
          // raf-read: counts frames only; nothing here reads layout.
          const tick = () => (--left <= 0 ? done() : requestAnimationFrame(tick));
          requestAnimationFrame(tick);
        }),
      count,
    );
  const moved = (from: Rect | undefined, to: Rect | undefined) =>
    from && to
      ? Math.max(
          Math.abs(from.top - to.top),
          Math.abs(from.bottom - to.bottom),
          Math.abs(from.left - to.left),
          Math.abs(from.right - to.right),
        )
      : 0;
  /// The largest move of each element per step: the composer and the pill from where each last stood,
  /// the last row only while it is the same row.
  const table = (all: Frame[]) => {
    const out: Record<string, { composer: number; pill: number; lastRow: number; frames: number }> = {};
    let composer: Rect | undefined;
    let pill: Rect | undefined;
    let row: Frame["row"];
    for (const frame of all) {
      const at = (out[frame.step] ??= { composer: 0, pill: 0, lastRow: 0, frames: 0 });
      at.frames += 1;
      if (frame.composer) {
        at.composer = Math.max(at.composer, moved(composer, frame.composer));
        composer = frame.composer;
      }
      if (frame.pill) {
        at.pill = Math.max(at.pill, moved(pill, frame.pill));
        pill = frame.pill;
      }
      if (frame.row?.rect) {
        if (row?.id === frame.row.id) at.lastRow = Math.max(at.lastRow, moved(row.rect, frame.row.rect));
        row = frame.row;
      }
    }
    for (const value of Object.values(out))
      for (const key of ["composer", "pill", "lastRow"] as const) value[key] = Math.round(value[key] * 10) / 10;
    return out;
  };
  const reveal = (page: Page) =>
    page.evaluate(() =>
      (window as { cmuxAcpmuxBridge?: { revealTurn?(value: string): void } }).cmuxAcpmuxBridge?.revealTurn?.(
        "subagent:a1",
      ),
    );

  test("opening a subagent, a streamed reply, chat <-> subagent and a wrapping prompt move nothing undeclared", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    await installPaintedFrames(page);
    try {
      await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
      await page.getByText("The lander is on it.").waitFor({ timeout: 25_000 });
      await page.locator(".acpmux-composer-box").waitFor();
      await settle(page, 30);
      await sample(page);
      // 1. The subagent opens in the pane; its composer mounts.
      await reveal(page);
      await page.locator("form.acpmux-composer[data-composer-relay]").waitFor({ timeout: 10_000 });
      await settle(page, 30);
      // 2. A reply streams into the chat while the subagent shows.
      await step(page, "stream");
      for (let index = 0; index < 12; index += 1) {
        chunk(` Step ${index + 1} of the rebase is done, and the next one is running now.\n\n`);
        await settle(page, 3);
      }
      await settle(page, 30);
      // 3. Back to the chat, then the subagent again.
      await step(page, "to-chat");
      await page.locator(".cv-subagent-of__pill").click();
      await page.waitForFunction(
        () => !document.querySelector("form.acpmux-composer[data-composer-relay]"),
        undefined,
        {
          timeout: 10_000,
        },
      );
      await settle(page, 30);
      await step(page, "to-subagent");
      await reveal(page);
      await page.locator("form.acpmux-composer[data-composer-relay]").waitFor({ timeout: 10_000 });
      await settle(page, 30);
      // 4. A prompt typed until it wraps: the composer's one declared move (composer-growth).
      await step(page, "type-wrap");
      await page.locator("form.acpmux-composer[data-composer-relay] .ProseMirror").first().click();
      await page.keyboard.type(
        "Please also check that the rebased branch still passes the gallery's undeclared-move run before it lands, and say which states changed and by how many pixels each one moved, then post the table on the pull request so the reviewer sees it before the merge",
      );
      await settle(page, 30);
      const sampled = await frames(page);
      const all = sampled.filter((frame) => frame.at === "painted");
      const result = table(all);
      const inCallbacks = table(sampled.filter((frame) => frame.at === "callbacks"));
      for (const [name, value] of Object.entries(result))
        console.log(
          `LAYOUT-MOTION subagent step=${name} ${JSON.stringify(value)} callbacksLastRow=${inCallbacks[name]?.lastRow ?? 0}`,
        );
      expect(all.some((frame) => frame.subagent)).toBe(true);
      // Nothing moves but the composer's own growth while the prompt wraps.
      for (const name of ["open-subagent", "stream", "to-chat", "to-subagent"]) {
        expect({ step: name, composer: result[name]?.composer ?? 0 }).toEqual({ step: name, composer: 0 });
        expect({ step: name, pill: result[name]?.pill ?? 0 }).toEqual({ step: name, pill: 0 });
      }
      // The transcript's last row holds still in every step, painted and as the frame's callbacks read
      // it. Back on the chat (`to-chat`) the chat's bottom stack replaces the subagent's in the switch's
      // commit; since #49749 both are the same Composer, so the last row must stand where it stood.
      for (const name of ["open-subagent", "stream", "to-chat", "to-subagent", "type-wrap"]) {
        expect({ step: name, lastRow: result[name]?.lastRow ?? 0 }).toEqual({ step: name, lastRow: 0 });
        expect({ step: name, callbacksLastRow: inCallbacks[name]?.lastRow ?? 0 }).toEqual({
          step: name,
          callbacksLastRow: 0,
        });
      }
      // The wrap grows the box upward: its bottom edge stays.
      const wrap = all.filter((frame) => frame.step === "type-wrap" && frame.composer);
      const bottoms = wrap.map((frame) => frame.composer!.bottom);
      expect(Math.max(...bottoms) - Math.min(...bottoms)).toBeLessThanOrEqual(0.5);
      expect(result["type-wrap"]?.pill ?? 0).toBe(0);
    } finally {
      await page.close();
    }
  });
});
