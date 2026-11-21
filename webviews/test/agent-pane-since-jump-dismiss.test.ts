// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Jump to new goes away once the reader is done with it (https://github.com/manaflow-ai/cmux/issues/40065).
// The pill shows over the transcript's top while "New since you looked" is out of view. It followed only
// the line's own IntersectionObserver, and the virtual transcript drops a row far from the view: a jump
// past the line (End, Jump to latest, a scrollbar drag, a fast wheel) took the row away before the
// observer saw it in view, so the pill kept the side it last saw ("below", its arrow down) at the latest
// message, where nothing could bring the line in view to clear it. Reaching the latest message by the
// reader's own move, or pressing the pill, now ends it for that mark.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux
// daemon whose chat has turns that ended since the person last looked.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-since-jump-dismiss.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-since-jump-dismiss: skipping (run `bunx playwright install chromium`)");
    describe.skip("since jump dismiss", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000400a5";
  const START = Date.UTC(2026, 10, 9, 9, 0, 0);
  const TURNS = 30;
  /// The person saw the first SEEN turns; the line sits in the middle of a transcript many panes tall,
  /// so at the latest message and at the top alike it is far out of view and not drawn.
  const SEEN = 15;
  const LAST = `Reply ${TURNS}: the last turn while you were away.`;
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [];
  for (let turn = 1; turn <= TURNS; turn++) {
    const text =
      turn === TURNS
        ? LAST
        : `Reply ${turn}: ${"a long paragraph that keeps the transcript taller than the pane. ".repeat(10)}`;
    steps.push(
      ["mux", "user_message", { text: `Step ${turn}` }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId: "agent-1",
            update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    );
  }
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Since jump dismiss",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: TURNS,
    updatedAt: START,
    unread: true,
    unreadTurns: TURNS - SEEN,
    seenSeq: SEEN * 4,
  };

  function answer(method: string): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the tests time only the pane.
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 600 } });
    await installPaintedFrames(page);
    await page.goto(url());
    await page.getByText(LAST).waitFor();
    await page.locator(".acpmux-since-jump").waitFor({ state: "attached" });
    await settle(page);
    return page;
  }

  /// A few painted frames: scroll events, the pacer's flush and the line's observer have all run.
  const settle = (page: Page) =>
    page.evaluate(async () => {
      for (let frame = 0; frame < 6; frame++) await window.cmuxPaintFrame();
    });

  /// What the reader sees: Jump to new, which way its arrow points, Jump to latest, and whether the
  /// line itself is drawn on screen.
  const state = (page: Page) =>
    page.evaluate(() => {
      const pill = document.querySelector<HTMLElement>(".acpmux-since-jump")!;
      // Jump to latest itself: Jump up shares its glass class and shows at the latest message by design.
      const latest = document.querySelector<HTMLElement>(".acpmux-jump-latest:not(.acpmux-jump-up)");
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const line = document.querySelector<HTMLElement>(".cv-since");
      const box = scroller.getBoundingClientRect();
      const at = line?.getBoundingClientRect();
      return {
        pill: pill.hasAttribute("data-shown"),
        side: pill.dataset.side,
        latest: latest?.hasAttribute("data-shown") ?? false,
        lineDrawn: Boolean(line),
        lineInView: Boolean(at && at.bottom > box.top && at.top < box.bottom),
        fromEnd: Math.round(scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop),
      };
    });

  /// The reader's wheel over the transcript, in steps the way a trackpad sends them.
  async function wheel(page: Page, dy: number, steps: number) {
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    for (let step = 0; step < steps; step++) await page.mouse.wheel(0, dy);
    await settle(page);
  }

  /// The offset set in one go, with no row in between drawn (setup only: no reader input).
  async function jumpTo(page: Page, where: "top" | "end") {
    await page.evaluate((where) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      scroller.scrollTop = where === "top" ? 0 : scroller.scrollHeight;
    }, where);
    await settle(page);
  }

  test("a chat opened at its latest message shows Jump to new, pointing up to the line", async () => {
    const page = await openChat();
    const opened = await state(page);
    expect(opened.lineInView).toBe(false);
    expect(opened.pill).toBe(true);
    expect(opened.side).toBe("above");
    await page.close();
  });

  test("pressing Jump to new hides it", async () => {
    const page = await openChat();
    // The banner's jump itself (UnreadBanner), not its Mark read or collapse chevron beside it.
    await page.locator(".acpmux-since-jump__body").click();
    await settle(page);
    await settle(page);
    const after = await state(page);
    expect(after.pill).toBe(false);
    await page.close();
  });

  test("scrolling up and back to the latest message hides Jump to new and Jump to latest", async () => {
    const page = await openChat();
    await wheel(page, -400, 3);
    expect((await state(page)).lineInView).toBe(false);
    // Down to the end, as far as the reader scrolls: rows measured on the way can move the end on.
    let back = await state(page);
    for (let tries = 0; tries < 6 && (tries === 0 || back.fromEnd > 2); tries++) {
      await wheel(page, 4000, 4);
      back = await state(page);
    }
    expect(back.fromEnd).toBeLessThanOrEqual(2);
    expect(back.pill).toBe(false);
    expect(back.latest).toBe(false);
    await page.close();
  });

  test("End from above the line to the latest message leaves no Jump to new pointing down", async () => {
    const page = await openChat();
    // Motion off (cmux's ui.animations or the system's Reduce Motion): End lands in one frame, over the
    // line without drawing it in view.
    await page.emulateMedia({ reducedMotion: "reduce" });
    // Up to the chat's top, then down until the line is drawn just below the view: Jump to new points
    // down to it, the state the reader left a chat reopened above its new turns in.
    await jumpTo(page, "top");
    let below = await state(page);
    for (let tries = 0; tries < 60 && !(below.lineDrawn && below.side === "below"); tries++) {
      await wheel(page, 200, 1);
      below = await state(page);
    }
    expect(below.lineInView).toBe(false);
    expect(below.pill).toBe(true);
    expect(below.side).toBe("below");
    // End with the page focused, the reader's own key for the latest message.
    await page.evaluate(() => (document.activeElement as HTMLElement | null)?.blur());
    await page.keyboard.press("End");
    await settle(page);
    await settle(page);
    const end = await state(page);
    expect(end.fromEnd).toBeLessThanOrEqual(2);
    expect(end.lineDrawn).toBe(false);
    expect(end.pill).toBe(false);
    expect(end.latest).toBe(false);
    // Back up a little, the line still far above: it stays away, since the reader went past it.
    await wheel(page, -300, 1);
    const up = await state(page);
    expect(up.lineInView).toBe(false);
    expect(up.pill).toBe(false);
    await page.close();
  });
});
