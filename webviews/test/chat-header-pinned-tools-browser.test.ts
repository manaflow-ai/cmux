// l10n-allow-file: test fixture prompts, replies and summaries, not shipped UI.
// The chat header's top-right tools stay pinned whatever the rolling summary says (header/ChatSummaryLine.tsx).
// Leo, 2026-11-23: the one-line summary banner "gets cut off" and the buttons "got glued in to the row", shifted down.
//
// Cause: the summary sat inline in the tools the page reports to the App (`pane.tabRowTools {width}`); the App offers
// the tab row only while that width is at most half the row (PaneTabRowSharing.fitsTabRow), so a summary in a split
// pane dropped the tools to a second row under the tabs. Now, in the tab row the summary is always a 24px chip (the
// reported width is the same for any text); in its own row it is the whole line or the chip, never a clipped line.
//
// The App's side is modeled as in chat-header-summary-row-fit-browser (PR 49863): the need is the last positive width
// reported, the row is offered while need <= room / 2, and a chat out of the row is laid under the strip.
// For no summary, a short one and a long one, at pane widths 280, 360, 480 and 800, in the tab row and in the chat's own
// row, it asserts (a) the trailing tools sit exactly where they sit with no summary, (b) in the tab row the width the
// page reports does not depend on the summary's text and the row is offered the same, (c) no tool intersects the title,
// the summary, the tabs or another tool, (d) the summary is whole (nothing clipped) or the chip.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-header-pinned-tools-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const PLAIN = "0190a000-0000-7000-8000-0000000000e1";
  const SHORT = "0190a000-0000-7000-8000-0000000000e2";
  const LONG = "0190a000-0000-7000-8000-0000000000e3";
  const START = Date.UTC(2026, 10, 23, 5, 0, 0);
  const REPLY = "Posted the stall history.";
  const SUMMARIES: Record<string, { text: string; next?: string }> = {
    [SHORT]: { text: "Menu planned." },
    [LONG]: {
      text: "I posted the build host's 14-day permission-stall history on the tracking issue (https://example.com/issues/7645) and the uploader's retry log",
      next: "Wait for the owner's read of both",
    },
  };
  const WIDTHS = [280, 360, 480, 800];
  const WINDOW = 1512;
  const INSET = 40;
  const STRIP = 28;

  const eventsFor = (sessionId: string) =>
    (
      [
        ["mux", "user_message", { text: "Post the stall history" }],
        ["mux", "turn_started", {}],
        [
          "in",
          "agent_message_chunk",
          {
            method: "session/update",
            params: {
              sessionId: "agent-1",
              update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: REPLY } },
            },
          },
        ],
        ["mux", "turn_result", { status: "completed" }],
      ] as [string, string, Record<string, unknown>][]
    ).map(([dir, kind, msg], index) => ({ sessionId, seq: index + 1, at: START + index * 1000, dir, kind, msg }));
  const sessionFor = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "release-coordinator",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
    ...(SUMMARIES[sessionId] ? { rollingSummary: SUMMARIES[sessionId] } : {}),
  });
  const ALL = [PLAIN, SHORT, LONG];

  function answer(method: string, params: { sessionId?: unknown } | undefined): unknown {
    const id = ALL.find((candidate) => candidate === params?.sessionId) ?? PLAIN;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: ALL.map(sessionFor) };
      case "_acpmux/attach":
        return { session: sessionFor(id), lastSeq: 4, events: eventsFor(id) };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 4 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (chat: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { sessionId?: unknown } };
          if (message.id !== undefined)
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params) }));
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
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(PLAIN));
        await warm.getByText(REPLY).waitFor({ timeout: 25_000 });
        await warm.close();
        break;
      } catch (error) {
        await warm.close();
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  type Box = { left: number; top: number; right: number; bottom: number };
  type Layout = {
    shared: boolean;
    reported: number;
    strip: Box;
    /** The tools but the summary's own chip, in DOM order. */
    tools: Box[];
    /** What shows of the summary: the whole line or the chip. */
    summary?: Box & { kind: string; clipped: boolean };
    title?: Box;
    room?: { slot: number; measure: number; header: number };
  };

  type Mode = "own row" | "tab row";

  /// Opens `chat` in a wide pane (the tab row offered, with the App modeled) or not (its own row), then sizes the pane.
  async function open(chat: string, width: number, mode: Mode): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: mode === "tab row" ? WINDOW : width, height: 640 } });
    await installPaintedFrames(page);
    await page.goto(url(chat));
    await page.getByText(REPLY).waitFor();
    if (mode === "tab row") {
      await page.waitForFunction(
        () =>
          Boolean((window as { cmuxAcpmuxBridge?: { applyTabRow?: unknown } }).cmuxAcpmuxBridge?.applyTabRow) &&
          Boolean(window.cmuxAcpmuxActions),
      );
    }
    if (chat !== PLAIN) await page.locator("[data-chat-summary]").first().waitFor({ state: "attached" });
    await page.evaluate(
      ({ inset, strip, tabRow }) => {
        type Bridge = { applyTabRow(row: unknown): void };
        const host = {
          need: 0,
          width: 0,
          offered: false,
          changes: 0,
          inset,
          strip,
          tabRow,
          room: () => window.innerWidth - inset,
          /// PaneContentView.layout: the row is offered while the need fits half of it.
          layout() {
            if (!host.tabRow) return;
            const bridge = (window as unknown as { cmuxAcpmuxBridge: Bridge }).cmuxAcpmuxBridge;
            const fits = host.need <= host.room() / 2;
            if (fits === host.offered) return;
            host.offered = fits;
            host.changes++;
            bridge.applyTabRow(fits ? { height: strip, trailingInset: inset } : { height: 0, trailingInset: 0 });
          },
        };
        (window as unknown as { __host: typeof host }).__host = host;
        if (!tabRow) return;
        window.cmuxAcpmuxActions!["pane.tabRowTools"] = async (params) => {
          const { width, need } = params as { width: number; need?: number };
          if (width > 0) host.need = typeof need === "number" && need > 0 ? Math.min(width, need) : width;
          if (width !== host.width) host.changes++;
          host.width = width;
          host.layout();
          return null;
        };
        host.layout();
      },
      { inset: INSET, strip: STRIP, tabRow: mode === "tab row" },
    );
    await settle(page);
    if (mode === "tab row" && width !== WINDOW) {
      await page.setViewportSize({ width, height: 640 });
      await page.evaluate(() => (window as unknown as { __host: { layout(): void } }).__host.layout());
      await settle(page);
    }
    return page;
  }

  async function settle(page: Page) {
    let last = -1;
    for (let still = 0, frame = 0; still < 4 && frame < 120; frame++) {
      const changes = await page.evaluate(async () => {
        await window.cmuxPaintFrame();
        return (window as unknown as { __host: { changes: number } }).__host.changes;
      });
      still = changes === last ? still + 1 : 0;
      last = changes;
    }
  }

  const layout = (page: Page) =>
    page.evaluate((): Layout => {
      const host = (
        window as unknown as {
          __host: { offered: boolean; width: number; room(): number; inset: number; strip: number; tabRow: boolean };
        }
      ).__host;
      const shared = host.tabRow && host.offered && host.width > 0;
      // A tab-row chat that is out of the row is laid under the strip (its page one strip lower).
      const dy = host.tabRow && !shared ? host.strip : 0;
      const box = (element: Element | null | undefined): Box | undefined => {
        if (!element) return undefined;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return undefined;
        return { left: rect.left, top: rect.top + dy, right: rect.right, bottom: rect.bottom + dy };
      };
      const given = shared ? Math.min(host.width, host.room() / 2) : 0;
      const header = document.querySelector(".acpmux-header")!;
      const tools = [...header.querySelectorAll(".acpmux-handoff-header-tools .acpmux-header-tool")]
        .filter((element) => !element.classList.contains("acpmux-chat-summary-chip"))
        .map((element) => box(element))
        .filter((value): value is Box => value !== undefined);
      const slot = header.querySelector("[data-chat-summary]");
      let summary: Layout["summary"];
      if (slot) {
        const kind = slot.getAttribute("data-chat-summary") ?? "";
        const shown = slot.querySelector<HTMLElement>(
          kind === "chip" ? ".acpmux-chat-summary-chip" : ".acpmux-chat-summary:not(.acpmux-chat-summary--measure)",
        );
        const at = box(shown);
        if (shown && at) {
          const parts = [shown, ...shown.querySelectorAll<HTMLElement>("*")];
          const slotBox = slot.getBoundingClientRect();
          const rect = shown.getBoundingClientRect();
          const clipped =
            parts.some((part) => part.scrollWidth > part.clientWidth + 0.5) || rect.right > slotBox.right + 0.5;
          summary = { ...at, kind, clipped };
        }
      }
      const measure = header.querySelector(".acpmux-chat-summary--measure")?.getBoundingClientRect().width;
      return {
        room: slot
          ? {
              slot: Math.round(slot.getBoundingClientRect().width),
              measure: Math.round(measure ?? 0),
              header: Math.round(header.getBoundingClientRect().width),
            }
          : undefined,
        shared,
        reported: host.width,
        strip: { left: 0, top: 0, right: window.innerWidth - host.inset - given, bottom: host.strip },
        tools,
        summary,
        title: box(header.querySelector(".acpmux-thread-title")),
      };
    });

  const intersects = (a: Box, b: Box) =>
    Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
    Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;
  const round = (b: Box) => ({
    left: Math.round(b.left),
    top: Math.round(b.top),
    right: Math.round(b.right),
    bottom: Math.round(b.bottom),
  });

  /// Every intersection that must not be.
  function overlaps(at: Layout): string[] {
    const found: string[] = [];
    at.tools.forEach((tool, index) => {
      if (at.shared && intersects(tool, at.strip)) found.push(`tool ${index} x tabs`);
      if (at.summary && intersects(tool, at.summary)) found.push(`tool ${index} x summary`);
      if (at.title && intersects(tool, at.title)) found.push(`tool ${index} x title`);
      at.tools.slice(index + 1).forEach((other, offset) => {
        if (intersects(tool, other)) found.push(`tool ${index} x tool ${index + 1 + offset}`);
      });
    });
    if (at.summary && at.shared && intersects(at.summary, at.strip)) found.push("summary x tabs");
    if (at.title && at.summary && intersects(at.title, at.summary)) found.push("title x summary");
    return found;
  }

  for (const mode of ["tab row", "own row"] as Mode[]) {
    describe(`the chat header's tools stay pinned whatever the summary says (${mode})`, () => {
      for (const width of WIDTHS) {
        test(`${width}px pane`, async () => {
          const at: Record<string, Layout> = {};
          for (const [state, chat] of [
            ["none", PLAIN],
            ["short", SHORT],
            ["long", LONG],
          ] as const) {
            const page = await open(chat, width, mode);
            at[state] = await layout(page);
            await page.close();
          }
          const line = (state: string) => {
            const l = at[state]!;
            return `${state}: ${mode === "own row" ? "own row" : l.shared ? "in row" : "under strip"}, title ${l.title ? Math.round(l.title.right - l.title.left) : "none"}, room ${JSON.stringify(l.room)}, reported ${l.reported}, summary ${
              l.summary
                ? `${l.summary.kind} ${Math.round(l.summary.right - l.summary.left)}px${l.summary.clipped ? " CLIPPED" : ""}`
                : "none"
            }, overlaps ${JSON.stringify(overlaps(l))}`;
          };
          console.log(`chat-header-pinned ${mode} ${width}px | ${line("none")} | ${line("short")} | ${line("long")}`);
          expect(at.none!.tools.length).toBeGreaterThan(0);
          for (const state of ["short", "long"]) {
            const l = at[state]!;
            // (a) the buttons never move: same row, same top, height and right edge as with no summary.
            expect({ state, shared: l.shared, tools: l.tools.map(round) }).toEqual({
              state,
              shared: at.none!.shared,
              tools: at.none!.tools.map(round),
            });
            // (c) nothing draws over anything.
            expect({ state, overlaps: overlaps(l) }).toEqual({ state, overlaps: [] });
            // (d) the summary is whole, or the chip; never a clipped line.
            expect(l.summary).toBeDefined();
            expect({ state, clipped: l.summary!.clipped }).toEqual({ state, clipped: false });
            if (mode === "tab row" || l.summary!.kind !== "line") {
              expect({ state, kind: l.summary!.kind, width: Math.round(l.summary!.right - l.summary!.left) }).toEqual({
                state,
                kind: "chip",
                width: 24,
              });
            }
          }
          expect(overlaps(at.none!)).toEqual([]);
          if (mode === "tab row") {
            // (b) the width the page reports does not depend on the summary's text.
            expect({ reported: at.long!.reported, shared: at.long!.shared }).toEqual({
              reported: at.short!.reported,
              shared: at.short!.shared,
            });
          }
        });
      }
    });
  }
});
