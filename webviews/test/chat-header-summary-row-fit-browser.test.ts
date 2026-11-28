// l10n-allow-file: test fixture prompts, replies and summaries, not shipped UI.
// The chat header's rolling summary (header/ChatSummaryLine.tsx) never moves the header's tools and never draws over
// anything. Leo, 2026-11-22: "why do we have this subheading here? im not sure if this is useful. well, at least for 1,
// it's overlapping. it's not good. idk why this was put in." and "like from the getgo it's just weird here. this
// doesn't seem like correct behaviour. the icons on the top right have gotten displaced due to putting things on a
// line. this is not how we should do ui."
//
// The summary sat in the tools the page reports to the App (`pane.tabRowTools`), so it was in their need, which decides
// whether a pane offers its tab row at all (PaneTabRowSharing.fitsTabRow: need <= half the row). A chat with a summary,
// split from a wide pane to half, a third or a quarter, needed more than half the row: the pane stopped offering it and
// the tools dropped to a second row under the tabs; in the row, tools wider than the half the strip gives up slid under
// the last tab and the + button. Now the summary is an accessory of the row (header/tabRow.ts TAB_ROW_ACCESSORY): in
// the width, never in the need, and only as wide as the room the tools leave.
//
// The App's side is modeled here as Swift does it (PaneContentView.layout, AgentPaneTabRow): the need is the last
// positive need reported (the width, from a page that sends none), the row is offered while need <= room / 2, the
// strip gives up min(width, room / 2), and a chat out of the row is laid under the strip (its page one strip lower).
// At each pane width, a chat with a summary and one without, both opened wide and then split: the tools' buttons sit
// at the same place on screen, and no button, nor the summary, intersects the strip's tabs and + button, another
// button, the title, or the transcript under the header.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane). With
// CHAT_HEADER_SHOTS=<dir> it also writes each case's header, cropped, with the strip's tabs drawn in.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("chat-header-summary-row-fit-browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const shots = process.env.CHAT_HEADER_SHOTS;
  if (shots) mkdirSync(shots, { recursive: true });

  const PLAIN = "0190a000-0000-7000-8000-0000000000d1";
  const SUMMED = "0190a000-0000-7000-8000-0000000000d2";
  const START = Date.UTC(2026, 10, 22, 5, 0, 0);
  const REPLY = "Posted the stall history.";
  // A 1512-point window (a 14-inch MacBook Pro), whole and split; the pane's own "…" at the row's end.
  const WINDOW = 1512;
  const WIDTHS = {
    full: WINDOW,
    half: WINDOW / 2,
    third: Math.round(WINDOW / 3),
    quarter: Math.round(WINDOW / 4),
    narrow: 320,
  };
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
    ...(sessionId === SUMMED
      ? {
          rollingSummary: {
            text: "I posted the build host's 14-day permission-stall history on the tracking issue (https://example.com/issues/7645)",
            next: "Wait for the owner's read",
          },
        }
      : {}),
  });

  function answer(method: string, params: { sessionId?: unknown } | undefined): unknown {
    const id = params?.sessionId === SUMMED ? SUMMED : PLAIN;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [sessionFor(PLAIN), sessionFor(SUMMED)] };
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
    tools: Box[];
    summary?: Box;
    title?: Box;
    under?: Box;
  };

  /// Opens `chat` in a wide pane with the App's side modeled (above), then splits the pane to `width`.
  async function open(chat: string, width: number): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: WINDOW, height: 640 } });
    await installPaintedFrames(page);
    await page.goto(url(chat));
    await page.getByText(REPLY).waitFor();
    await page.waitForFunction(
      () =>
        Boolean((window as { cmuxAcpmuxBridge?: { applyTabRow?: unknown } }).cmuxAcpmuxBridge?.applyTabRow) &&
        Boolean(window.cmuxAcpmuxActions),
    );
    if (chat === SUMMED) await page.locator("[data-chat-summary]").first().waitFor({ state: "attached" });
    await page.evaluate(
      ({ inset, strip }) => {
        type Bridge = { applyTabRow(row: unknown): void };
        const bridge = (window as unknown as { cmuxAcpmuxBridge: Bridge }).cmuxAcpmuxBridge;
        const host = {
          need: 0,
          width: 0,
          offered: false,
          changes: 0,
          inset,
          strip,
          room: () => window.innerWidth - inset,
          /// PaneContentView.layout: the row is offered while the need fits half of it.
          layout() {
            const fits = host.need <= host.room() / 2;
            if (fits === host.offered) return;
            host.offered = fits;
            host.changes++;
            bridge.applyTabRow(fits ? { height: strip, trailingInset: inset } : { height: 0, trailingInset: 0 });
          },
        };
        (window as unknown as { __host: typeof host }).__host = host;
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
      { inset: INSET, strip: STRIP },
    );
    await settle(page);
    if (width !== WINDOW) {
      await page.setViewportSize({ width, height: 640 });
      // The pane lays out at its new size before the page measures again (AgentPaneTabRow keeps the need).
      await page.evaluate(() => (window as unknown as { __host: { layout(): void } }).__host.layout());
      await settle(page);
    }
    return page;
  }

  /// Painted frames until the App's model and the page have stopped answering each other.
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

  /// Where things are on screen: the page's boxes, one strip lower while the chat is out of the row.
  const layout = (page: Page) =>
    page.evaluate((): Layout => {
      const host = (
        window as unknown as {
          __host: { offered: boolean; width: number; room(): number; inset: number; strip: number };
        }
      ).__host;
      const shared = host.offered && host.width > 0;
      const dy = shared ? 0 : host.strip;
      const box = (element: Element | null | undefined): Box | undefined => {
        if (!element) return undefined;
        const rect = element.getBoundingClientRect();
        if (rect.width <= 0 || rect.height <= 0) return undefined;
        return { left: rect.left, top: rect.top + dy, right: rect.right, bottom: rect.bottom + dy };
      };
      const given = shared ? Math.min(host.width, host.room() / 2) : 0;
      const header = document.querySelector(".acpmux-header")!;
      const tools = [...header.querySelectorAll(".acpmux-handoff-header-tools .acpmux-header-tool")]
        .map((element) => box(element))
        .filter((value): value is Box => value !== undefined);
      return {
        shared,
        reported: host.width,
        // The pane's tabs and + button: the strip, from the row's start to where it gave the tools room.
        strip: { left: 0, top: 0, right: window.innerWidth - host.inset - given, bottom: host.strip },
        tools,
        summary: box(header.querySelector("[data-chat-summary]")),
        title: box(header.querySelector(".acpmux-thread-title")),
        under: box(document.querySelector(".acpmux-scroll")),
      };
    });

  const intersects = (a: Box, b: Box) =>
    Math.min(a.right, b.right) - Math.max(a.left, b.left) > 0.5 &&
    Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top) > 0.5;
  const area = (a: Box, b: Box) =>
    Math.max(0, Math.min(a.right, b.right) - Math.max(a.left, b.left)) *
    Math.max(0, Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top));
  const round = (b: Box) => ({
    left: Math.round(b.left),
    top: Math.round(b.top),
    right: Math.round(b.right),
    bottom: Math.round(b.bottom),
  });

  /// Every intersection that must not be, with its area in square CSS pixels.
  function overlaps(at: Layout): string[] {
    const found: string[] = [];
    const named: [string, Box][] = at.tools.map((tool, index) => [`tool ${index}`, tool]);
    if (at.summary) named.push(["summary", at.summary]);
    for (const [name, b] of named) {
      if (at.shared && intersects(b, at.strip)) found.push(`${name} x tabs (${Math.round(area(b, at.strip))}px²)`);
      if (at.under && intersects(b, at.under)) found.push(`${name} x transcript (${Math.round(area(b, at.under))}px²)`);
      if (name !== "summary" && at.summary && intersects(b, at.summary))
        found.push(`${name} x summary (${Math.round(area(b, at.summary))}px²)`);
    }
    if (at.title && at.summary && intersects(at.title, at.summary)) found.push("title x summary");
    return found;
  }

  async function shoot(page: Page, name: string, at: Layout) {
    if (!shots) return;
    // The strip's tabs and + button, drawn where the App draws them, so a crop shows what the person sees.
    await page.evaluate((at) => {
      const strip = document.createElement("div");
      strip.style.cssText = `position:fixed;left:0;top:0;width:${at.strip.right}px;height:${at.strip.bottom}px;z-index:99999;display:flex;align-items:center;gap:4px;padding:0 6px;box-sizing:border-box;background:rgba(127,127,127,.12);font:12px system-ui;color:#888;pointer-events:none;overflow:hidden`;
      strip.innerHTML = `<span style="flex:0 1 160px;min-width:40px;height:20px;border-radius:6px;background:rgba(127,127,127,.25);padding:0 8px;line-height:20px;white-space:nowrap;overflow:hidden">release-coordinator</span><span style="flex:0 1 160px;min-width:40px;height:20px;border-radius:6px;background:rgba(127,127,127,.15);padding:0 8px;line-height:20px;white-space:nowrap;overflow:hidden">Terminal</span><span style="flex:none">+</span>`;
      // A chat out of the row is laid under the strip: its page one strip lower.
      if (!at.shared) document.body.style.transform = `translateY(${at.strip.bottom}px)`;
      document.documentElement.append(strip);
    }, at);
    await page.evaluate(async () => void (await window.cmuxPaintFrame()));
    const width = page.viewportSize()!.width;
    await page.screenshot({ path: path.join(shots, `${name}.png`), clip: { x: 0, y: 0, width, height: 64 } });
  }

  describe("the chat header's summary moves nothing and covers nothing", () => {
    for (const [split, width] of Object.entries(WIDTHS)) {
      test(`${split} pane (${width}px)`, async () => {
        const plainPage = await open(PLAIN, width);
        const plain = await layout(plainPage);
        await shoot(plainPage, `${split}-without-summary`, plain);
        await plainPage.close();
        const summedPage = await open(SUMMED, width);
        const summed = await layout(summedPage);
        await shoot(summedPage, `${split}-with-summary`, summed);
        await summedPage.close();
        console.log(
          `chat-header-fit ${split} ${width}px: without summary ${plain.shared ? "in the row" : "under the strip"}, reported ${plain.reported};` +
            ` with summary ${summed.shared ? "in the row" : "under the strip"}, reported ${summed.reported},` +
            ` summary ${summed.summary ? `${Math.round(summed.summary.right - summed.summary.left)}px` : "hidden"};` +
            ` overlaps ${JSON.stringify(overlaps(summed))}`,
        );
        expect(plain.tools.length).toBeGreaterThan(0);
        // The tools sit where they sit without a summary: same row, same place.
        expect({ shared: summed.shared, tools: summed.tools.map(round) }).toEqual({
          shared: plain.shared,
          tools: plain.tools.map(round),
        });
        expect(overlaps(plain)).toEqual([]);
        expect(overlaps(summed)).toEqual([]);
      });
    }
  });
});
