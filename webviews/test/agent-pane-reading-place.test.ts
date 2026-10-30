// l10n-allow-file: test fixture prompts, not shipped UI.
// A long chat reopens where the reader left it, even far above its newest page (cx-odzaz). The pane
// opens a chat on its tail (#20536); the host keeps the row the reader rested on (cx-6bgzj). When
// that row is older than the tail, the pane pages back to it before it shows the chat, then puts
// it where it was, instead of opening at the latest message.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-reading-place.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-reading-place: skipping (run `bunx playwright install chromium`)");
    describe.skip("reading place", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000b22b";
  const START = Date.UTC(2026, 9, 1, 9, 0, 0);
  const TURNS = 500;
  const update = (value: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: value },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const steps: [string, string, Record<string, unknown>][] = [];
  const questionSeq = new Map<number, number>();
  for (let n = 1; n <= TURNS; n++) {
    questionSeq.set(n, steps.length + 1);
    steps.push(
      ["mux", "user_message", { text: `Question ${n}` }],
      ["mux", "turn_started", {}],
      ["in", "agent_message_chunk", chunk(`Answer ${n}: the build on this branch passes, `)],
      ["in", "agent_message_chunk", chunk("and the checks on the merged head are green.")],
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
  const lastSeq = events.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq,
  };
  function page(params: Record<string, any>) {
    const limit = Number(params.limit ?? 2000);
    if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
      const after = events.filter((event) => event.seq > params.afterSeq);
      return { events: after.slice(0, limit), hasMore: after.length > limit, lastSeq };
    }
    const before = events.filter((event) => event.seq < (params.beforeSeq ?? Infinity));
    return { events: before.slice(Math.max(0, before.length - limit)), hasMore: before.length > limit, lastSeq };
  }
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, ...page(params) };
      case "_acpmux/events":
        return page(params);
      default:
        return null;
    }
  }

  /// Requests the daemon has not answered yet.
  let inflight = 0;
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
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          // A page comes a little later, as over a network.
          inflight++;
          setTimeout(() => {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
            inflight--;
          }, 30);
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

  /// Opens the chat with the host keeping `anchor` as where it last rested.
  async function reopen(anchor: { rowId: string; offset: number } | null): Promise<Page> {
    const tab = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(tab);
    // Every painted frame: the first question drawn while the transcript shows, and whether Jump to latest
    // showed while it did not.
    await tab.addInitScript(() => {
      const frames: { shown: string | null; jump: boolean }[] = [];
      (window as any).openFrames = frames;
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const bubble = scroller?.querySelector(".cv-user__bubble");
        if (scroller && bubble) {
          const hidden = scroller.hasAttribute("data-seeking");
          frames.push({
            shown: hidden ? null : bubble.textContent,
            jump: hidden && document.querySelector(".acpmux-jump-latest[data-shown]") !== null,
          });
        }
      });
    });
    await tab.addInitScript((kept) => {
      const saved: unknown[] = [];
      (window as any).savedAnchors = saved;
      (window as any).cmuxAcpmuxActions = {
        "chat.scrollAnchor.get": async () => kept,
        "chat.scrollAnchor": async (params: unknown) => {
          saved.push(params);
          return null;
        },
      };
    }, anchor);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await tab.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    return tab;
  }
  /// Until the daemon has answered every request and the transcript, done seeking, has held its
  /// scroll position over three painted frames with no animation left running.
  const settle = async (tab: Page) => {
    for (let tries = 0; tries < 50; tries++) {
      await tab.evaluate(async () => {
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await new Promise<void>((resolve) => {
          let last = -1;
          let still = 0;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            const top = scroller && !scroller.hasAttribute("data-seeking") ? scroller.scrollTop : -1;
            still = top >= 0 && top === last ? still + 1 : 0;
            last = top;
            if (still < 2) return true;
            resolve();
            return false;
          });
        });
      });
      if (inflight === 0) return;
    }
  };
  /// Where `text`'s bubble sits from the top of the transcript's view; undefined when it is not drawn.
  const bubbleTop = (tab: Page, text: string) =>
    tab.evaluate((wanted) => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      const bubble = [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].find(
        (element) => element.textContent === wanted,
      );
      return bubble ? bubble.getBoundingClientRect().top - view.top : undefined;
    }, text);

  /// The space above a user bubble inside its row, so offset 0 puts the bubble just that far down.
  const rowPad = (tab: Page) =>
    tab.evaluate(() => {
      const bubble = document.querySelector<HTMLElement>(".cv-user__bubble");
      const row = bubble?.closest<HTMLElement>(".acpmux-row");
      return bubble && row ? bubble.getBoundingClientRect().top - row.getBoundingClientRect().top : 0;
    });

  test("a long chat reopens at the turn the reader left it on, far above its newest page", async () => {
    const tab = await reopen({ rowId: `user-${questionSeq.get(100)}`, offset: 0 });
    const errors: string[] = [];
    tab.on("pageerror", (error) => errors.push(error.message));
    await tab.getByText("Question 100", { exact: true }).waitFor({ timeout: 60_000 });
    await settle(tab);

    // The row the reader rested on is back at the top of the view, and the view did not open at the
    // latest message first.
    const top = await bubbleTop(tab, "Question 100");
    expect(top).toBeDefined();
    expect(Math.abs(top! - (await rowPad(tab)))).toBeLessThan(40);
    expect(await bubbleTop(tab, `Question ${TURNS}`)).toBeUndefined();
    // The first frame the transcript showed was already the reader's place, never the latest
    // turns, and Jump to latest never showed over the hidden transcript.
    const frames = await tab.evaluate(() => (window as any).openFrames as { shown: string | null; jump: boolean }[]);
    const firstShown = frames.find((frame) => frame.shown !== null)?.shown;
    expect(Number(firstShown?.replace("Question ", ""))).toBeLessThanOrEqual(100);
    expect(frames.filter((frame) => frame.jump)).toEqual([]);
    // Paging back never saved another place over the kept one.
    const saved = await tab.evaluate(() => (window as any).savedAnchors as { rowId: string | null }[]);
    expect(saved.filter((anchor) => anchor.rowId !== `user-${questionSeq.get(100)}`)).toEqual([]);
    expect(errors).toEqual([]);
    await tab.close();
  });

  test("a chat left at its latest message reopens there", async () => {
    const tab = await reopen(null);
    await tab.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    await settle(tab);
    const top = await bubbleTop(tab, `Question ${TURNS}`);
    const height = await tab.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.clientHeight);
    expect(top).toBeDefined();
    expect(top!).toBeGreaterThan(0);
    expect(top!).toBeLessThan(height);
    await tab.close();
  });
});
