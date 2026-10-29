// l10n-allow-file: test fixture prompts, replies and titles, not shipped UI.
// cmux-web-test-timeout: 300
//
// Leo, 2026-10-29: "I clicked into your subagent and it's just like, okay, there's nothing there.
// It's just a blank. Well, it loaded after a while." This times that open: a chat with a running
// sub-session in its tray, a click on the sub-session's row, and the new tab the app opens for it
// (`chat.offer.open`), against a stand-in acpmux that answers like a busy daemon. Measured from the
// click to the first frame of the new tab that shows the sub-session's transcript
// (time-to-first-content), and held to SUB_OPEN_MS.
//
// The stand-in host serves what the app host does for this flow: the in-memory tail store
// (`chat.tail`, `chat.tail.get`, AgentPaneTailCache.swift) shared by every tab, and the open itself,
// which here starts the new tab's page. Every other host call is refused, as an older host would.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type BrowserContext, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("subsession-open-perf.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("subsession-open-perf: skipping (run `bunx playwright install chromium`)");
    describe.skip("sub-session open perf", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 29, 9, 0, 0);
  const PARENT = "0190a000-0000-7000-8000-00000000aaaa";
  const CHILD = "0190a000-0000-7000-8000-00000000bbbb";
  const CHILD_TITLE = "codex-review";
  const MARKER = "Codex review verdict reached.";
  /// The sub-session's transcript: a long review, so its pages are real work to read.
  const CHILD_TURNS = 300;
  /// A busy daemon (Leo's: hundreds of queued messages, ~50 sub-sessions): every call waits
  /// CALL_MS, and a page of a long chat (an attach, or the newest page of events) PAGE_MS. The
  /// page read is charged the attach's whole cost, so the hand-over gains nothing from a cheaper read.
  const CALL_MS = 120;
  const PAGE_MS = 900;
  /// The new tab draws the sub-session inside this, from the click (the brief: never a blank pane).
  /// Includes the dev bundle's page boot (an unminified React in Vite's dev server).
  const SUB_OPEN_MS = 1_500;
  const RUNS = 3;

  const say = (sessionId: string, text: string) => [
    "in",
    "agent_message_chunk",
    {
      method: "session/update",
      params: { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text } } },
    },
  ];
  const transcript = (sessionId: string, turns: number, marker: string) => {
    const steps: unknown[][] = [];
    for (let turn = 0; turn < turns; turn += 1) {
      steps.push(["mux", "user_message", { text: `Turn ${turn}: check the retry path at its head` }]);
      steps.push(["mux", "turn_started", {}]);
      steps.push(say(sessionId, `Read \`uploader.ts\` for turn ${turn}. The retry loop now honours the backoff.`));
      if (turn === turns - 1) steps.push(say(sessionId, marker));
      steps.push(["mux", "turn_result", { status: "completed" }]);
    }
    return steps.map(([dir, kind, msg], at) => ({ sessionId, seq: at + 1, at: START + at * 1000, dir, kind, msg }));
  };
  const events = new Map([
    [PARENT, transcript(PARENT, 4, "Started the review sub-session.")],
    [CHILD, transcript(CHILD, CHILD_TURNS, MARKER)],
  ]);
  const listed = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/project",
    title: sessionId === CHILD ? CHILD_TITLE : "Main chat",
    harness: sessionId === CHILD ? "codex" : "claude",
    family: sessionId === CHILD ? "codex" : "claude",
    status: sessionId === CHILD ? "running" : "idle",
    turnCount: sessionId === CHILD ? CHILD_TURNS : 4,
    createdAt: START,
    updatedAt: START + 60_000,
    ...(sessionId === CHILD ? { startedBy: PARENT } : {}),
  });
  function answer(method: string, params: Record<string, any>): unknown {
    const sessionId = String(params.sessionId ?? "");
    const all = events.get(sessionId) ?? [];
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [listed(PARENT), listed(CHILD)] };
      case "_acpmux/attach":
        return { session: listed(sessionId), lastSeq: all.length, events: all.slice(-400), hasMore: all.length > 400 };
      case "_acpmux/events":
        return { events: all.slice(-400), hasMore: all.length > 400, lastSeq: all.length };
      default:
        return null;
    }
  }
  const delay = (method: string, params: Record<string, any>) =>
    (method === "_acpmux/attach" || method === "_acpmux/events") && params?.sessionId === CHILD ? PAGE_MS : CALL_MS;

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const params = message.params ?? {};
          const result = answer(message.method, params);
          setTimeout(
            () => ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result })),
            delay(message.method, params),
          );
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

  /// The app host for one run: a tail store every tab of the context shares, and `chat.offer.open`,
  /// which opens the sub-session's tab as the app does. Reached through the page's native handler.
  const installHost = async (context: BrowserContext, opened: (sessionId: string) => void) => {
    const tails = new Map<string, unknown>();
    await context.exposeBinding("__cmuxHost", (_source, method: string, params: Record<string, any>) => {
      switch (method) {
        case "chat.tail.get":
          return { ok: true, value: tails.get(String(params.sessionId)) ?? null };
        case "chat.tail":
          if (params.tail) tails.set(String(params.sessionId), params.tail);
          else tails.delete(String(params.sessionId));
          return { ok: true, value: null };
        case "chat.offer.open":
          opened(String(params.sessionId));
          return { ok: true, value: null };
        default:
          return { ok: false, error: { code: "unsupported", message: `unsupported: ${method}` } };
      }
    });
    await context.addInitScript(() => {
      const host = (window as unknown as { __cmuxHost: (m: string, p: unknown) => Promise<unknown> }).__cmuxHost;
      (window as unknown as { webkit: unknown }).webkit = {
        messageHandlers: {
          agentSession: { postMessage: (message: { method: string; params: unknown }) => host(message.method, message.params) },
        },
      };
    });
  };

  /// Watches the new tab from its first script: the wall clock of the first animation frame whose
  /// page shows `marker`. One rAF chain, stopped by the find or by `limitMs`.
  const watchFirstContent = (tab: Page, marker: string, limitMs: number) =>
    tab.addInitScript(
      ({ marker, limitMs }) => {
        const began = Date.now();
        (window as unknown as { __firstContent: Promise<number | null> }).__firstContent = new Promise((resolve) => {
          const tick = () => {
            if (document.body?.innerText.includes(marker)) return resolve(Date.now());
            if (Date.now() - began > limitMs) return resolve(null);
            requestAnimationFrame(tick);
          };
          requestAnimationFrame(tick);
        });
      },
      { marker, limitMs },
    );

  /// One open: the parent chat drawn, a click on the sub-session's tray row, the new tab the host
  /// opens for it; milliseconds from the click to that tab's first frame with the transcript.
  const openOnce = async (): Promise<number | null> => {
    const context = await browser!.newContext({ viewport: { width: 1000, height: 760 } });
    try {
      let child: Promise<Page> | undefined;
      await installHost(context, (sessionId) => {
        child ??= (async () => {
          const tab = await context.newPage();
          await watchFirstContent(tab, MARKER, 15_000);
          void tab.goto(url(sessionId));
          return tab;
        })();
      });
      const parent = await context.newPage();
      await parent.goto(url(PARENT));
      await parent.getByText("Started the review sub-session.").waitFor({ timeout: 25_000 });
      const row = parent.getByText(CHILD_TITLE, { exact: true }).first();
      await row.waitFor({ timeout: 10_000 });
      const clickedAt = Date.now();
      await row.click();
      for (let wait = 0; !child && wait < 100; wait += 1) await new Promise((resolve) => setTimeout(resolve, 20));
      if (!child) throw new Error("the click did not ask the host to open the sub-session (chat.offer.open)");
      const tab = await child;
      await tab.waitForFunction(() => "__firstContent" in window);
      const drawnAt = (await tab.evaluate(
        () => (window as unknown as { __firstContent: Promise<number | null> }).__firstContent,
      )) as number | null;
      return drawnAt === null ? null : drawnAt - clickedAt;
    } finally {
      await context.close();
    }
  };

  test("a sub-session opened from the tray shows its transcript in its new tab, never a blank pane", async () => {
    // A warm-up open, so the dev server's first compile is not what the runs time.
    await openOnce().catch(() => undefined);
    const runs: (number | null)[] = [];
    for (let run = 0; run < RUNS; run += 1) runs.push(await openOnce());
    const shown = runs.map((ms) => (ms === null ? "never" : ms.toFixed(0))).join("/");
    console.log(
      `::notice title=subsession-open-perf::${CHILD_TURNS}-turn sub-session, ${CALL_MS} ms a call, ${PAGE_MS} ms a page: ` +
        `click to first content in its new tab ${shown} ms (budget ${SUB_OPEN_MS} ms)`,
    );
    for (const ms of runs) {
      expect(ms).not.toBeNull();
      expect(ms!).toBeLessThan(SUB_OPEN_MS);
    }
  });
});
