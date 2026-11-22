// cmux-web-test-timeout: 420
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A chat opened after a relaunch draws its prompt rail once: after the first frame that shows the chat,
// the rail and the rows on screen do not draw again while nothing in the chat changes (Leo, 2026-11-22,
// after a relaunch to update: "and then the scroll rail re-rednered. and then more shit re-rendered.
// all of these need fucking help").
//
// The real pane as it ships (vite.config.acpmux-pane.mjs, production React, React Compiler on) against a
// stand-in acpmux over a WebSocket: a long chat, opened on its latest page, with older history, a prompt
// index and two bookmarks, every reply at once. Counted from the first painted frame that shows rows and
// the rail until the page has been quiet: the rail's React renders (`acpmuxPerf.render("rail")`), the
// rail's DOM changes, ticks taken out and put back, the rail's animations, and the renders and DOM
// changes of the rows that frame showed.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/rail-restore-paints-once-browser.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { loadTurn, type LoadStep } from "../src/agent-session/acpmux/loadFixture";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("rail-restore-paints-once-browser.test.ts", async () => {
  if (!(await probeEngineOrSkip("rail-restore-paints-once-browser", "chromium", chromium))) {
    describe.skip("rail paints once", () => test("chromium", () => {}));
    return;
  }
  setDefaultTimeout(400_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const SESSION = "0190a000-0000-7000-8000-0000000000c5";
  const TURNS = 120;
  const ATTACH_LIMIT = 40;
  const base = 1_791_000_000_000;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/mock/project",
    title: "Long chat",
    harness: "claude",
    status: "idle",
    steering: true,
    queuePaused: false,
    queued: 0,
    queue: [],
    turnCount: TURNS,
    createdAt: base,
    updatedAt: base + TURNS * 60_000,
  });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>, at: number) =>
    void events.push({ sessionId: SESSION, seq: events.length + 1, at, dir, kind, msg });
  const update = (body: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: `agent-${SESSION}`, update: body },
  });
  const prompts: number[] = [];
  const recordStep = (step: LoadStep, turn: number, at: number) => {
    if ("update" in step) record("in", String(step.update.sessionUpdate), update(step.update), at);
    else if (step.mux === "user_message") {
      record("mux", "user_message", { ...step.msg, promptId: `p-${turn}` }, at);
      prompts.push(events.length);
    } else if (step.mux === "turn_started")
      record("mux", "turn_started", { turnId: `t-${turn}`, promptId: `p-${turn}` }, at);
    else record("mux", step.mux, step.msg ?? {}, at);
  };
  for (let turn = 0; turn < TURNS; turn++)
    for (const step of loadTurn(turn, { diffLines: 20, logLines: 20 })) recordStep(step, turn, base + turn * 60_000);
  // Two marks: one on a prompt near the end, one far up.
  const bookmarks = [prompts[TURNS - 3]!, prompts[10]!];

  const page = (params: Record<string, any>, attach: boolean) => {
    const kinds: string[] = Array.isArray(params.kinds) ? params.kinds : [];
    const transcript = (event: Event) =>
      kinds.length === 0 ||
      kinds.includes(event.kind) ||
      (kinds.includes("transcript") && event.kind !== "available_commands_update");
    const after = Number(params.afterSeq ?? 0);
    const before = params.beforeSeq === undefined ? Infinity : Number(params.beforeSeq);
    const newest = params.beforeSeq !== undefined || (attach && params.afterSeq === undefined);
    const asked = params.limit === undefined ? Infinity : Math.max(1, Number(params.limit));
    const limit = attach ? Math.min(asked, ATTACH_LIMIT) : asked;
    const maxBytes = params.maxBytes === undefined ? Infinity : Number(params.maxBytes);
    const out: Event[] = [];
    let bytes = 0;
    let hasMore = false;
    const take = (event: Event) => {
      if (event.seq <= after || event.seq >= before || !transcript(event)) return true;
      if (out.length >= limit) return !(hasMore = true);
      bytes += JSON.stringify(event.msg).length + event.kind.length + 120;
      if (out.length > 0 && bytes > maxBytes) return !(hasMore = true);
      out.push(event);
      return true;
    };
    if (newest) {
      for (let i = events.length - 1; i >= 0 && take(events[i]!); i -= 1);
      out.reverse();
    } else for (let i = 0; i < events.length && take(events[i]!); i += 1);
    return { events: out, hasMore };
  };
  const turnOpener = (first: Event | undefined, hasMore: boolean) => {
    const opens = (event: Event) => event.dir === "mux" && event.kind === "user_message";
    if (!hasMore || !first || first.seq <= 1 || opens(first)) return null;
    for (let i = first.seq - 2; i >= 0; i -= 1) if (opens(events[i]!)) return events[i]!;
    return null;
  };
  const asked = new Map<string, number>();
  function answer(method: string, params: Record<string, any>): unknown {
    asked.set(method, (asked.get(method) ?? 0) + 1);
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach": {
        const p = page(params, true);
        return {
          session: summary(),
          ...p,
          lastSeq: events.length,
          pageThrough: events.length,
          turnOpener: turnOpener(p.events[0], p.hasMore),
        };
      }
      case "_acpmux/events":
        return { ...page(params, false), lastSeq: events.length };
      case "_acpmux/bookmark_get":
        return { bookmarks };
      default:
        return null;
    }
  }

  const out = fs.mkdtempSync(path.join(process.env.TMPDIR ?? os.tmpdir(), "rail-restore-paints-once-"));
  let statics: ReturnType<typeof Bun.serve> | undefined;
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    const { build } = await import("vite");
    await build({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      build: { outDir: out, emptyOutDir: true },
      logLevel: "error",
    });
    statics = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      async fetch(request) {
        const pathname = new URL(request.url).pathname;
        const file = Bun.file(path.join(out, pathname === "/" ? "index.html" : pathname));
        return (await file.exists()) ? new Response(file) : new Response("not found", { status: 404 });
      },
    });
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open() {},
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
          );
        },
      },
    });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await statics?.stop(true);
    await daemon?.stop(true);
    fs.rmSync(out, { recursive: true, force: true });
  });
  const url = () =>
    `http://127.0.0.1:${statics!.port}/#endpoint=${encodeURIComponent(`ws://127.0.0.1:${daemon!.port}/`)}&token=t&session=${SESSION}`;

  type Report = {
    firstFrameMs: number;
    frames: number;
    renders: Record<string, number>;
    railMutations: Record<string, number>;
    railMutationFrames: number;
    railRemoved: number;
    railAnimations: string[];
    railTicksFirst: number;
    railTicksLast: number;
    settledRows: string[];
    rowMutations: Record<string, number>;
    details: string[];
  };

  /// Installs, before the page's own scripts, a watch that waits for the first painted frame showing rows
  /// and the rail, then records the rail's and those rows' DOM changes, frame by frame, until `__railReport`.
  const watch = (p: Page) =>
    p.addInitScript(() => {
      const w = window as any;
      const state = {
        start: 0,
        frames: 0,
        settledRows: [] as string[],
        railMutations: {} as Record<string, number>,
        railMutationFrames: 0,
        railRemoved: 0,
        railAnimations: new Set<string>(),
        rowMutations: {} as Record<string, number>,
        details: [] as string[],
        railTicksFirst: 0,
        changedThisFrame: false,
      };
      w.__railState = state;
      const bump = (into: Record<string, number>, key: string) => (into[key] = (into[key] ?? 0) + 1);
      const describe = (change: MutationRecord) =>
        change.type === "attributes"
          ? `attr:${change.attributeName}`
          : change.type === "characterData"
            ? "text"
            : `children${change.removedNodes.length ? "-" : ""}${change.addedNodes.length ? "+" : ""}`;
      const visibleRows = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return [];
        const view = scroller.getBoundingClientRect();
        return [...scroller.querySelectorAll<HTMLElement>("article.acpmux-row[data-row-id]")].filter((node) => {
          const box = node.getBoundingClientRect();
          return box.height > 0 && box.bottom > view.top && box.top < view.bottom;
        });
      };
      let observer: MutationObserver | undefined;
      const begin = () => {
        const rows = visibleRows();
        state.settledRows = rows.map((row) => row.dataset.rowId!);
        state.railTicksFirst = document.querySelectorAll(".acpmux-minimap__tick").length;
        state.start = performance.now();
        // Enables and zeroes the render counts from this frame on.
        w.cmuxAcpmuxDebug?.renders();
        const settled = new Set(state.settledRows);
        observer = new MutationObserver((list) => {
          for (const change of list) {
            const target = change.target instanceof Element ? change.target : change.target.parentElement;
            if (!target) continue;
            if (target.closest(".acpmux-minimap")) {
              bump(state.railMutations, describe(change));
              if (change.type === "attributes" && change.attributeName !== "aria-label")
                state.details.push(
                  `rail ${target.getAttribute("data-tick") ?? target.className} ${change.attributeName}: ${change.oldValue} -> ${target.getAttribute(change.attributeName!)}`,
                );
              for (const gone of change.removedNodes)
                if (
                  gone instanceof Element &&
                  (gone.matches(".acpmux-minimap__entry, .acpmux-minimap__tick") ||
                    gone.querySelector(".acpmux-minimap__tick"))
                )
                  state.railRemoved += 1;
              state.changedThisFrame = true;
              continue;
            }
            // A rail removed whole (its parent is outside it) is a rail change too.
            for (const gone of change.removedNodes)
              if (
                gone instanceof Element &&
                (gone.matches(".acpmux-minimap") || gone.querySelector(".acpmux-minimap"))
              ) {
                bump(state.railMutations, "rail-removed");
                state.railRemoved += 1;
                state.changedThisFrame = true;
              }
            const row = target.closest<HTMLElement>("article.acpmux-row[data-row-id]");
            if (row && settled.has(row.dataset.rowId!)) {
              // A settled row's own box being placed (top) is the transcript's layout, not the row drawing.
              if (change.type === "attributes" && target === row && change.attributeName === "style") continue;
              bump(state.rowMutations, `${row.dataset.rowId}:${describe(change)}`);
              const nodeName = (node: Node) =>
                node instanceof Element
                  ? `${node.tagName.toLowerCase()}.${[...node.classList].join(".")}`
                  : node.nodeName;
              if (change.type === "childList")
                state.details.push(
                  `row ${row.dataset.rowId} in ${nodeName(target)}: -[${[...change.removedNodes].map(nodeName).join(",")}] +[${[...change.addedNodes].map(nodeName).join(",")}]`,
                );
              else if (change.type === "attributes" && change.attributeName !== "aria-posinset")
                state.details.push(
                  `row ${row.dataset.rowId} ${nodeName(target)} ${change.attributeName}: ${change.oldValue} -> ${target.getAttribute(change.attributeName!)}`,
                );
            }
          }
        });
        observer.observe(document.documentElement, {
          subtree: true,
          childList: true,
          attributes: true,
          attributeOldValue: true,
          characterData: true,
        });
      };
      const loop = () => {
        w.cmuxAfterPaint(() => {
          if (!state.start) {
            if (visibleRows().length > 0 && document.querySelector(".acpmux-minimap__tick")) begin();
            return;
          }
          state.frames += 1;
          if (state.changedThisFrame) state.railMutationFrames += 1;
          state.changedThisFrame = false;
          const rail = document.querySelector(".acpmux-minimap");
          for (const animation of rail?.getAnimations({ subtree: true }) ?? []) {
            const name = (animation as CSSAnimation).animationName ?? (animation as CSSTransition).transitionProperty;
            if (animation.playState === "running") state.railAnimations.add(String(name));
          }
        });
      };
      const wait = () => (typeof w.cmuxAfterPaint === "function" ? loop() : setTimeout(wait, 0));
      wait();
      w.__railReport = () => {
        observer?.disconnect();
        return {
          firstFrameMs: Math.round(state.start),
          frames: state.frames,
          renders: w.cmuxAcpmuxDebug?.renders() ?? {},
          railMutations: state.railMutations,
          railMutationFrames: state.railMutationFrames,
          railRemoved: state.railRemoved,
          railAnimations: [...state.railAnimations],
          railTicksFirst: state.railTicksFirst,
          railTicksLast: document.querySelectorAll(".acpmux-minimap__tick").length,
          settledRows: state.settledRows,
          rowMutations: state.rowMutations,
          details: state.details.slice(0, 80),
        };
      };
    });

  /// Waits for the watch's first frame, then for QUIET_MS with no change in the rail (capped).
  const settle = async (p: Page) => {
    await p.waitForFunction(() => (window as any).__railState?.start > 0, null, { timeout: 60_000 });
    await p.evaluate(
      () =>
        new Promise<void>((done) => {
          const state = (window as any).__railState;
          let last = JSON.stringify([state.railMutations, state.rowMutations]);
          let quietSince = performance.now();
          const tick = () => {
            const now = JSON.stringify([state.railMutations, state.rowMutations]);
            if (now !== last) {
              last = now;
              quietSince = performance.now();
            }
            if (performance.now() - quietSince > 2_000 || performance.now() - state.start > 12_000) done();
            else setTimeout(tick, 100);
          };
          tick();
        }),
    );
  };

  type Way = "first open" | "relaunch" | "reload";
  const run = async (label: Way): Promise<Report> => {
    const context = await browser!.newContext({ viewport: { width: 1200, height: 900 } });
    let p = await context.newPage();
    try {
      await installPaintedFrames(p);
      await watch(p);
      await p.goto(url());
      await settle(p);
      if (label === "relaunch") {
        // A relaunch: a new page with what the app keeps across launches (localStorage), and none of
        // the last page's memory or its sessionStorage copy.
        await p.close();
        p = await context.newPage();
        await installPaintedFrames(p);
        await watch(p);
        await p.goto(url());
        await settle(p);
      } else if (label === "reload") {
        // A reload of the pane: its sessionStorage copy kept.
        await p.reload();
        await settle(p);
      }
      const report = (await p.evaluate(() => (window as any).__railReport())) as Report;
      const rowRenders = Object.entries(report.renders)
        .filter(([name]) => /^(row|content|frame|tool):/.test(name))
        .filter(([name]) => report.settledRows.some((id) => name.endsWith(`:${id}`) || name.includes(`:${id}`)));
      console.log(
        `rail-restore ${label}: ${JSON.stringify({
          ...report,
          rail: report.renders.rail ?? 0,
          railTicks: report.renders["rail:ticks"] ?? 0,
          railTick: report.renders["rail:tick"] ?? 0,
          settledRowRenders: Object.fromEntries(rowRenders),
          asked: Object.fromEntries(asked),
        })}`,
      );
      return report;
    } finally {
      await context.close();
    }
  };

  // The chat's first open on this computer: nothing kept, so what acpmux answers after the attach
  // (the bookmarks, the prompt index) may still draw. Measured, not held to zero.
  test("first open: measured", async () => {
    const report = await run("first open");
    expect(report.frames).toBeGreaterThan(10);
  });
  for (const label of ["relaunch", "reload"] as const)
    test(`${label}: after the first frame of the chat the rail and the rows on screen draw no more`, async () => {
      const report = await run(label);
      expect(report.frames).toBeGreaterThan(10);
      expect(report.railTicksLast).toBe(report.railTicksFirst);
      expect({
        rail: report.renders.rail ?? 0,
        railTicks: report.renders["rail:ticks"] ?? 0,
        railTick: report.renders["rail:tick"] ?? 0,
        railMutationFrames: report.railMutationFrames,
        railRemoved: report.railRemoved,
        railAnimations: report.railAnimations,
        rowMutations: report.rowMutations,
      }).toEqual({
        rail: 0,
        railTicks: 0,
        railTick: 0,
        railMutationFrames: 0,
        railRemoved: 0,
        railAnimations: [],
        rowMutations: {},
      });
    });
});
