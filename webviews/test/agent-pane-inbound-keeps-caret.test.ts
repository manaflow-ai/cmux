// The composer's caret, selection and focus belong to the person (Leo, 2026-10-20: the caret jumped
// to the start of the prompt mid-sentence when another agent's steer or queued message arrived). In
// the real agent pane, a stand-in acpmux daemon's chat runs a turn while the person types; another
// agent's message then queues behind the turn, is sent into it as a steer, and the turn ends. After
// each, and after the daemon re-adopts the chat and the connection drops and comes back, the prompt
// keeps its text, its selection, its focus and its editor (no remount).
//
// Real Chromium and WebKit (the app's pane is a WKWebView) from Playwright; skipped where they are
// not installed (the hosted webviews job).
import { afterAll, beforeAll, beforeEach, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-inbound-keeps-caret.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    for (const engine of [chromium, webkit]) await (await engine.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-inbound-keeps-caret: skipping (run `bunx playwright install chromium webkit`)");
    describe.skip("inbound messages keep the caret", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "inbound-session";
  const turn = { turnId: "turn-1", promptId: "p-turn", startedAt: Date.now(), prompt: "Refactor the parser" };
  let queue: { promptId: string; prompt: string }[] = [];
  let running = true;
  let steering = true;
  let model = "sonnet";
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Refactor the parser",
    harness: "claude",
    status: running ? "running" : "idle",
    steering,
    model,
    queued: queue.length,
    queue,
    ...(running ? { turn } : {}),
    updatedAt: Date.now(),
  });
  const opening = [
    {
      sessionId: SESSION,
      seq: 1,
      at: Date.now(),
      dir: "mux",
      kind: "user_message",
      msg: { text: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
    { sessionId: SESSION, seq: 2, at: Date.now(), dir: "mux", kind: "turn_started", msg: {} },
  ];
  let seq = opening.length;

  type Socket = { send(data: string): void; close(): void };
  let socket: Socket | undefined;
  /// Called once the daemon has answered an attach.
  let onAttach: (() => void) | undefined;
  /// Resolves once the daemon has answered the pane's next attach.
  const attachedAgain = () =>
    new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("the pane never attached again within 15 s")), 15_000);
      onAttach = () => {
        clearTimeout(timer);
        onAttach = undefined;
        resolve();
      };
    });
  const event = (kind: string, msg: Record<string, unknown>) =>
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: SESSION, seq: ++seq, at: Date.now(), dir: "mux", kind, msg },
      }),
    );
  /// A harness update acpmux relays (`dir: "in"`), as the streamed answer comes.
  const update = (sessionUpdate: string, fields: Record<string, unknown>) =>
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: {
          sessionId: SESSION,
          seq: ++seq,
          at: Date.now(),
          dir: "in",
          kind: sessionUpdate,
          msg: { method: "session/update", params: { update: { sessionUpdate, ...fields } } },
        },
      }),
    );
  const changed = (recordKind: string) =>
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId: SESSION, session: summary(), kind: "queue", recordKind, seq },
      }),
    );

  // The chat's durable draft, kept as acpmux keeps it (`_acpmux/draft_set`, then `_acpmux/draft_get`
  // answers it): a reconnect's read finds what the page wrote, as with the real daemon. A mock that
  // acknowledged writes and forgot them answered every read with no draft, which the composer takes
  // as the draft cleared elsewhere (composerDraft.ts `hydratedDraft`). Each test starts with none.
  let draft: string | undefined;
  function answer(method: string, params?: Record<string, unknown>): unknown {
    switch (method) {
      case "_acpmux/draft_get":
        return { draft: draft ?? null };
      case "_acpmux/draft_set":
        draft = typeof params?.text === "string" && params.text ? params.text : undefined;
        return {};
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: seq, events: opening };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers: Record<string, Browser> = {};
  beforeEach(() => {
    draft = undefined;
  });
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          socket = ws;
        },
        message(ws, raw) {
          socket = ws;
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          const result = answer(message.method, message.params);
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
          if (message.method === "_acpmux/attach") onAttach?.();
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
    browsers.chromium = await chromium.launch({ headless: true });
    browsers.webkit = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    for (const browser of Object.values(browsers)) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  let probes = 0;
  /// Resolves once the pane has taken every record the daemon sent and drawn it, with any effect
  /// that starts run: another chat listed after them lands behind them on the socket, so the page
  /// lists it only once it has taken the rest; two painted frames follow.
  async function caughtUp(page: Page) {
    const sessionId = `probe-${++probes}`;
    socket!.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/session_changed",
        params: { sessionId, kind: "created", session: { sessionId, cwd: "/home/dev/api", harness: "claude" } },
      }),
    );
    await page.waitForFunction(
      (sessionId) =>
        (window as any).cmuxAcpmuxDebug
          .chatState()
          .sessions.some((session: { sessionId: string }) => session.sessionId === sessionId),
      sessionId,
      { timeout: 15_000 },
    );
    for (let frame = 0; frame < 2; frame++) await page.evaluate(() => window.cmuxPaintFrame());
  }

  /// The prompt's text, the selection in it as plain-text offsets, whether it has focus, and
  /// whether it is still the editor the test marked (a remount makes a new one).
  const where = (page: Page) =>
    page.evaluate(() => {
      const editor = document.querySelector<HTMLElement>(".acpmux-composer-prompt .acpmux-md");
      const selection = document.getSelection();
      const offset = (node: Node | null | undefined, at: number) => {
        if (!editor || !node || !editor.contains(node)) return -1;
        const range = document.createRange();
        range.setStart(editor, 0);
        range.setEnd(node, at);
        return range.toString().length;
      };
      return {
        text: editor?.textContent ?? "",
        start: offset(selection?.anchorNode, selection?.anchorOffset ?? 0),
        end: offset(selection?.focusNode, selection?.focusOffset ?? 0),
        focused: Boolean(editor && editor.contains(document.activeElement)),
        same: editor?.dataset.testMark === "kept",
      };
    });

  // What WebKit does when the web view gives the keyboard to the app and gets it back: the window
  // blurs (the editor stays the active element), the selection is cleared, the caret is put at the
  // editor's start while the view is away, then the window (and with `element`, the editor) gets
  // focus again, longer after any earlier focus than ProseMirror's own 200 ms guard looks back.
  const handOff = (page: Page, element: boolean) =>
    page.evaluate(async (element) => {
      const editor = document.querySelector<HTMLElement>(".acpmux-composer-prompt .acpmux-md");
      const selection = document.getSelection();
      if (!editor || !selection) return;
      // fixed-wait: ProseMirror's focus guard compares Date.now() with the last focus (200 ms); the hand-off has to come later in wall time, and faking the page's clock would stop its frames.
      const settle = () => new Promise((resolve) => setTimeout(resolve, 250));
      window.dispatchEvent(new window.Event("blur"));
      if (element) editor.dispatchEvent(new window.FocusEvent("blur"));
      selection.removeAllRanges();
      await settle();
      selection.collapse(editor.querySelector("p")?.firstChild ?? editor, 0);
      await settle();
      window.dispatchEvent(new window.Event("focus"));
      if (element) editor.dispatchEvent(new window.FocusEvent("focus"));
    }, element);

  // The same hand-back, but WebKit's caret at the start comes after the focus, and late: the page is
  // busy drawing what just came in (Leo's Mac ran at load 260), so the selectionchange lands well past
  // ProseMirror's 200 ms guard and the field's own window. No key or click comes between.
  const lateStart = (page: Page, element: boolean) =>
    page.evaluate(async (element) => {
      const editor = document.querySelector<HTMLElement>(".acpmux-composer-prompt .acpmux-md");
      const selection = document.getSelection();
      if (!editor || !selection) return;
      // fixed-wait: the late placement has to come later in wall time than the 200 ms and 100 ms guards look; faking the clock would stop the page's frames.
      const late = () => new Promise((resolve) => setTimeout(resolve, 350));
      window.dispatchEvent(new window.Event("blur"));
      if (element) editor.dispatchEvent(new window.FocusEvent("blur"));
      selection.removeAllRanges();
      window.dispatchEvent(new window.Event("focus"));
      if (element) editor.dispatchEvent(new window.FocusEvent("focus"));
      await late();
      selection.collapse(editor.querySelector("p")?.firstChild ?? editor, 0);
    }, element);

  describe("inbound messages leave the prompt as the person left it", () => {
    // Leo 2026-10-21: "the caret jumps to the beginning on focus... while im typing... After a steer...
    // Or I guess maybe a queued message, sends." Each inbound step is followed by the keyboard coming
    // back with a late caret at the start; the caret and the text stay as the person left them.
    test.each(["chromium", "webkit"])(
      "%s: a caret the browser puts at the start long after the keyboard comes back is put back, after each inbound step",
      async (engine) => {
        running = true;
        steering = true;
        queue = [];
        model = "sonnet";
        const page = await browsers[engine]!.newPage({ viewport: { width: 900, height: 760 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
        await page.goto(
          `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`,
        );
        const prompt = page.locator(".acpmux-composer-prompt .acpmux-md");
        await prompt.waitFor();
        await prompt.click();
        await page.keyboard.type("fix the flaky retry test");
        await page.keyboard.press("Home");
        for (let i = 0; i < 8; i++) await page.keyboard.press("ArrowRight");
        for (let i = 0; i < 5; i++) await page.keyboard.press("Shift+ArrowRight");
        await page.evaluate(() => {
          const editor = document.querySelector<HTMLElement>(".acpmux-composer-prompt .acpmux-md");
          if (editor) editor.dataset.testMark = "kept";
        });
        const before = await where(page);
        expect(before).toEqual({ text: "fix the flaky retry test", start: 8, end: 13, focused: true, same: true });

        const from = { kind: "agent_message", from: "acp:b7", fromName: "b7", msgId: "m-late" };
        const steps: [string, () => void, boolean][] = [
          [
            "another agent's message queued",
            () => {
              queue = [{ promptId: "agent-late", prompt: "tests pass" }];
              event("queued", { promptId: "agent-late", text: "tests pass", position: 1, _meta: { provenance: from } });
              changed("queued");
            },
            false,
          ],
          [
            "the queued message sent as a steer",
            () => {
              queue = [];
              event("dequeued", { promptId: "agent-late" });
              event("user_message", {
                text: "tests pass",
                promptId: "agent-late",
                turnId: "turn-1",
                steer: true,
                _meta: { provenance: from },
              });
              changed("dequeued");
            },
            true,
          ],
          [
            "the turn ended",
            () => {
              running = false;
              event("turn_result", { status: "completed" });
              changed("turn_result");
            },
            false,
          ],
          [
            "a snapshot update (model changed)",
            () => {
              model = "opus";
              changed("config_option_update");
            },
            true,
          ],
        ];
        for (const [name, step, element] of steps) {
          step();
          await caughtUp(page);
          await lateStart(page, element);
          await caughtUp(page);
          expect({ step: name, ...(await where(page)) }).toEqual({ step: name, ...before });
        }
        // The person's own move to the start still goes there.
        await page.keyboard.press("Home");
        await caughtUp(page);
        expect(await where(page)).toMatchObject({ text: "fix the flaky retry test", start: 0, end: 0, focused: true });
        await page.close();
      },
    );

    test.each(["chromium", "webkit"])(
      "%s: another agent's queued message, its steer, the turn's end, a re-adopt and a reconnect keep the caret mid-text",
      async (engine) => {
        running = true;
        steering = true;
        queue = [];
        const page = await browsers[engine]!.newPage({ viewport: { width: 900, height: 760 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
        await page.goto(
          `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`,
        );
        const prompt = page.locator(".acpmux-composer-prompt .acpmux-md");
        await prompt.waitFor();
        await prompt.click();
        await page.keyboard.type("fix the flaky retry test");
        // The caret goes after "fix the " and "flaky" is selected, as a person would.
        await page.keyboard.press("Home");
        for (let i = 0; i < 8; i++) await page.keyboard.press("ArrowRight");
        for (let i = 0; i < 5; i++) await page.keyboard.press("Shift+ArrowRight");
        await page.evaluate(() => {
          const editor = document.querySelector<HTMLElement>(".acpmux-composer-prompt .acpmux-md");
          if (editor) editor.dataset.testMark = "kept";
        });
        const before = await where(page);
        expect(before).toEqual({ text: "fix the flaky retry test", start: 8, end: 13, focused: true, same: true });

        const from = { kind: "agent_message", from: "acp:a162", fromName: "a162", msgId: "m-1" };
        // Each step, and what the pane shows once it has taken it.
        const steps: [string, () => void, (() => Promise<unknown>)?][] = [
          [
            "queued",
            () => {
              queue = [{ promptId: "agent-1", prompt: "rebase first" }];
              event("queued", { promptId: "agent-1", text: "rebase first", position: 1, _meta: { provenance: from } });
              changed("queued");
            },
          ],
          [
            "steered",
            () => {
              queue = [];
              event("dequeued", { promptId: "agent-1" });
              event("user_message", {
                text: "rebase first",
                promptId: "agent-1",
                turnId: "turn-1",
                steer: true,
                _meta: { provenance: from },
              });
              changed("dequeued");
            },
          ],
          [
            "answered",
            () => {
              running = false;
              event("turn_result", { status: "completed" });
              changed("turn_result");
            },
          ],
          // The daemon re-adopted its sessions while the person typed (2026-10-20, 01:54 to 02:30):
          // the chat's summary came again with steering off.
          [
            "re-adopted",
            () => {
              steering = false;
              changed("adopted");
            },
          ],
          // The connection drops and the pane reconnects and attaches the chat again.
          [
            "reconnected",
            () => {
              reattached = attachedAgain();
              socket!.close();
            },
            () => reattached!,
          ],
        ];
        let reattached: Promise<void> | undefined;
        for (const [name, step, shown] of steps) {
          step();
          await shown?.();
          await caughtUp(page);
          expect({ step: name, ...(await where(page)) }).toEqual({ step: name, ...before });
        }
        // A caret move the last step set off a little later lands before the page answers again.
        await caughtUp(page);
        expect({ step: "after", ...(await where(page)) }).toEqual({ step: "after", ...before });
        await page.close();
      },
    );

    // Typing goes on while the pane changes under it: the answer streams in, the window loses and
    // regains focus, the page hides and shows, and the model changes. Every key lands at the caret.
    test.each(["chromium", "webkit"])(
      "%s: keys typed while the turn streams, the window refocuses and the page hides land at the caret",
      async (engine) => {
        running = true;
        steering = true;
        queue = [];
        model = "sonnet";
        const page = await browsers[engine]!.newPage({ viewport: { width: 900, height: 760 } });
        await installPaintedFrames(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
        await page.goto(
          `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`,
        );
        const prompt = page.locator(".acpmux-composer-prompt .acpmux-md");
        await prompt.waitFor();
        await prompt.click();
        await page.keyboard.type("fix the retry test");
        await page.keyboard.press("Home");
        for (let i = 0; i < 8; i++) await page.keyboard.press("ArrowRight");

        let words = 0;
        const stream = setInterval(
          () => update("agent_message_chunk", { content: { type: "text", text: `word${++words} ` } }),
          25,
        );
        const steps: [string, () => Promise<unknown> | void][] = [
          ["streaming", () => {}],
          [
            "window refocus",
            () =>
              page.evaluate(() => {
                window.dispatchEvent(new window.Event("blur"));
                window.dispatchEvent(new window.Event("focus"));
              }),
          ],
          [
            "page hidden and shown",
            () =>
              page.evaluate(() => {
                for (const state of ["hidden", "visible"]) {
                  Object.defineProperty(document, "visibilityState", { value: state, configurable: true });
                  Object.defineProperty(document, "hidden", { value: state === "hidden", configurable: true });
                  document.dispatchEvent(new window.Event("visibilitychange"));
                }
              }),
          ],
          [
            "model changed",
            () => {
              model = "opus";
              changed("config_option_update");
            },
          ],
          // The web view gives the keyboard to the app (another pane, tab or workspace, the palette)
          // and gets it back. WebKit clears the selection when it lets go and puts a contenteditable's
          // caret at its start, which ProseMirror takes as the person's before any focus comes back.
          ["keyboard handed back to the window", () => handOff(page, false)],
          ["keyboard handed back to the window and the prompt", () => handOff(page, true)],
        ];
        let typed = "";
        try {
          for (const [name, step] of steps) {
            await step();
            const key = String.fromCharCode(97 + typed.length);
            await page.keyboard.type(key, { delay: 40 });
            typed += key;
            // The key is in the prompt, wherever it landed; then the pane takes what came meanwhile.
            await page.waitForFunction(
              (length) => document.querySelector(".acpmux-composer-prompt .acpmux-md")?.textContent?.length === length,
              "fix the retry test".length + typed.length,
            );
            await caughtUp(page);
            const at = await where(page);
            expect({ step: name, text: at.text, start: at.start, end: at.end, focused: at.focused }).toEqual({
              step: name,
              text: `fix the ${typed}retry test`,
              start: 8 + typed.length,
              end: 8 + typed.length,
              focused: true,
            });
          }
        } finally {
          clearInterval(stream);
        }
        await page.close();
      },
    );
  });
});
