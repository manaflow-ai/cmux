// l10n-allow-file: test fixture prompts, replies and mode names, not shipped UI.
// Leo, 2026-10-19: switching chats flickers (the permission UI, the transcript). A chat switch
// should draw the old chat until the new one can draw whole, then the new one: never a frame in
// between (an empty transcript, the access chip without its mode, one chat's rows under the
// other's chip). acpmux's session list carries no permission modes and the attach takes a while,
// as in the app. A per-frame sampler in the page records what each frame shows from the switch
// until it settles; every frame must be all old or all new.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-switch-frames.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-switch-frames: skipping (run `bunx playwright install chromium`)");
    describe.skip("switch frames", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 19, 9, 0, 0);
  /// How long acpmux takes to answer an attach (a busy daemon, a large chat). This intentionally
  /// exceeds the old 400 ms switch hold so a slow switch proves it never paints a blank transcript.
  const ATTACH_MS = 600;
  const modes = (current: string) => ({
    currentModeId: current,
    availableModes: [
      { id: "default", name: "Manual", description: "Always ask before making changes" },
      { id: "acceptEdits", name: "Accept edits", description: "Edit files without asking" },
      { id: "bypassPermissions", name: "Bypass permissions", description: "Accepts all permissions" },
    ],
  });
  const chat = (sessionId: string, title: string, reply: string, mode: string) => {
    const listed = {
      sessionId,
      cwd: "/home/dev/uploader",
      title,
      harness: "claude",
      family: "claude",
      model: "claude-sonnet",
      status: "idle",
      turnCount: 1,
      updatedAt: START,
      currentModeId: mode,
    };
    const steps: [string, string, Record<string, unknown>][] = [
      ["mux", "user_message", { text: title }],
      ["mux", "turn_started", {}],
      [
        "in",
        "agent_message_chunk",
        {
          method: "session/update",
          params: {
            sessionId,
            update: {
              sessionUpdate: "agent_message_chunk",
              content: { type: "text", text: reply },
            },
          },
        },
      ],
      ["mux", "turn_result", { status: "completed" }],
    ];
    const events = steps.map(([dir, kind, msg], index) => ({
      sessionId,
      seq: index + 1,
      at: START + index * 1000,
      dir,
      kind,
      msg,
    }));
    return { listed, attached: { ...listed, modes: modes(mode) }, events };
  };
  const A = chat("0190a000-0000-7000-8000-0000000000f1", "Uploader retry", "Retry added.", "bypassPermissions");
  const B = chat("0190a000-0000-7000-8000-0000000000f2", "Docs pass", "Docs updated.", "default");
  const chats = new Map([A, B].map((entry) => [entry.listed.sessionId, entry]));

  let attaches = 0;
  let malformedAttachFor: string | undefined;
  let malformedAttachConsumed = false;
  let freshSessionId: string | undefined;
  let freshSessionCreated = 0;
  let freshSessionAttached = false;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [] } },
        };
      case "_acpmux/watch":
        // acpmux's list names each chat's mode, not the modes it offers (protocol/session.rs).
        return { sessions: [...chats.values()].map((entry) => entry.listed) };
      case "_acpmux/attach": {
        attaches += 1;
        const sessionId = String(params.sessionId);
        if (freshSessionId && sessionId === freshSessionId) {
          freshSessionAttached = true;
          return {
            session: {
              ...B.attached,
              sessionId,
              title: "Fresh recovery",
              turnCount: 0,
              events: [],
            },
            lastSeq: 0,
            events: [],
          };
        }
        const entry = chats.get(sessionId)!;
        return { session: entry.attached, lastSeq: entry.events.length, events: entry.events };
      }
      case "session/new":
        freshSessionCreated += 1;
        return freshSessionId ? { sessionId: freshSessionId } : {};
      case "_acpmux/events":
        return {
          events: [],
          hasMore: false,
          lastSeq: chats.get(String(params.sessionId))?.events.length ?? 0,
        };
      default:
        return null;
    }
  }
  const sockets = new Set<Bun.ServerWebSocket<unknown>>();
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session?: string, newTab = false) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const params = new URLSearchParams({ endpoint, token: "t" });
    if (session) params.set("session", session);
    if (newTab) {
      params.set("new", "");
      params.set("newtab", "");
    }
    return `http://127.0.0.1:${port}/#${params.toString()}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, any>;
          };
          if (message.id === undefined) return;
          const reply = () =>
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, message.params ?? {}),
              }),
            );
          if (message.method === "_acpmux/attach" && malformedAttachFor === String(message.params?.sessionId ?? "")) {
            malformedAttachFor = undefined;
            malformedAttachConsumed = true;
            // Events without a matching session summary are malformed too: the client must not
            // treat a partial page as an accepted target.
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { events: [B.events[0]] } }));
            return;
          }
          if (message.method === "_acpmux/attach") setTimeout(reply, ATTACH_MS);
          else reply();
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
        await warm.goto(url(B.listed.sessionId));
        await warm.getByText("Docs updated.").waitFor({ timeout: 25_000 });
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
    // Not awaited: after the reconnect test's forced close, Bun's stop can wait on that socket for good.
    void daemon?.stop(true);
  });

  test("a chat switch draws the old chat, then the new one, never a frame in between", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url(A.listed.sessionId));
    await page.getByText("Retry added.").waitFor();
    const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
    await page.waitForFunction(
      (selector) => document.querySelector(selector)?.textContent === "Bypass permissions",
      CHIP,
    );
    await page.evaluate((selector) => {
      const frames: { at: number; chip: string; old: boolean; fresh: boolean; text: string }[] = [];
      (window as unknown as { switchFrames: typeof frames }).switchFrames = frames;
      const start = performance.now();
      window.cmuxAfterPaint(() => {
        const text = document.body.innerText;
        frames.push({
          at: performance.now() - start,
          chip: document.querySelector(selector)?.textContent ?? "",
          old: text.includes("Retry added."),
          fresh: text.includes("Docs updated."),
          text: text.slice(0, 160).replace(/\s+/g, " "),
        });
        return performance.now() - start < 1500;
      });
      const actions = (window as { cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>> })
        .cmuxAcpmuxActions;
      void actions?.["chat.select"]?.({ sessionId: "0190a000-0000-7000-8000-0000000000f2" });
    }, CHIP);
    await page.getByText("Docs updated.").waitFor();
    await page.waitForFunction(() => {
      const frames = (window as unknown as { switchFrames: { at: number }[] }).switchFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1400;
    });
    const frames = await page.evaluate(
      () =>
        (
          window as unknown as {
            switchFrames: { at: number; chip: string; old: boolean; fresh: boolean }[];
          }
        ).switchFrames,
    );
    await page.close();
    const oldFrame = (frame: (typeof frames)[number]) =>
      frame.old && !frame.fresh && frame.chip === "Bypass permissions";
    const newFrame = (frame: (typeof frames)[number]) => frame.fresh && !frame.old && frame.chip === "Manual";
    const between = frames.filter((frame) => !oldFrame(frame) && !newFrame(frame));
    const firstNew = frames.findIndex(newFrame);
    const span = between.length ? between.at(-1)!.at - between[0].at : 0;
    console.log(
      `switch-frames: ${frames.length} frames, ${between.length} in between over ${span.toFixed(0)} ms ` +
        `(first: ${JSON.stringify(between[0] ?? null)}), new chat whole at ${firstNew < 0 ? "never" : frames[firstNew].at.toFixed(0) + " ms"}`,
    );
    expect(firstNew).toBeGreaterThanOrEqual(0);
    expect(between).toEqual([]);
  });

  test("opening an old chat from New Tab does not flash its new-chat hero", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      (window as unknown as { __cmuxNewTabContext: unknown }).__cmuxNewTabContext = {
        kind: "agent",
        hotkeys: {},
        layout: "a",
        home: "/home/dev",
      };
    });
    await page.goto(url(undefined, true));
    await page.waitForSelector(".acpmux-newtab, .nt-location");
    await page.locator('.nt-field [contenteditable="true"], input.acpmux-newtab-field').first().fill("Docs");
    await page.getByText("Docs pass", { exact: true }).waitFor();
    await page.evaluate(() => {
      const frames: { at: number; newTab: boolean; empty: boolean; transcript: boolean }[] = [];
      const state = window as unknown as { oldChatFrames: typeof frames; oldChatFrameStart: number };
      state.oldChatFrames = frames;
      const start = performance.now();
      state.oldChatFrameStart = start;
      window.cmuxAfterPaint(() => {
        frames.push({
          at: performance.now() - start,
          newTab: Boolean(document.querySelector(".acpmux-newtab")),
          empty: Boolean(document.querySelector(".acpmux-empty")),
          transcript: document.body.innerText.includes("Docs updated."),
        });
        return performance.now() - start < 1200;
      });
    });
    await page.getByText("Docs pass", { exact: true }).click();
    const clickAt = await page.evaluate(() => {
      const state = window as unknown as { oldChatFrameStart: number };
      return performance.now() - state.oldChatFrameStart;
    });
    await page.getByText("Docs updated.", { exact: true }).waitFor();
    await page.waitForFunction(() => {
      const frames = (window as unknown as { oldChatFrames: { at: number }[] }).oldChatFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1100;
    });
    const frames = await page.evaluate(
      () =>
        (
          window as unknown as {
            oldChatFrames: { at: number; newTab: boolean; empty: boolean; transcript: boolean }[];
          }
        ).oldChatFrames,
    );
    await page.close();
    const afterOpen = frames.filter((frame) => frame.at >= clickAt);
    const flash = afterOpen.filter((frame) => frame.empty && !frame.transcript);
    const unclassified = afterOpen.filter((frame) => !frame.newTab && !frame.transcript);
    console.log(
      `old-chat: ${afterOpen.length} post-open frames, ${flash.length} new-chat hero frames, ` +
        `${unclassified.length} unclassified frames` +
        (flash.length ? ` (first: ${JSON.stringify(flash[0])})` : ""),
    );
    expect(flash).toEqual([]);
    expect(unclassified).toEqual([]);
    expect(afterOpen.some((frame) => frame.transcript)).toBe(true);
  });

  test("a stale old-chat select keeps the New Tab hero after a malformed attach", async () => {
    malformedAttachFor = B.listed.sessionId;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      (window as unknown as { __cmuxNewTabContext: unknown }).__cmuxNewTabContext = {
        kind: "agent",
        hotkeys: {},
        layout: "a",
        home: "/home/dev",
      };
    });
    await page.goto(url(undefined, true));
    await page.waitForSelector(".acpmux-newtab, .nt-location");
    await page.locator('.nt-field [contenteditable="true"], input.acpmux-newtab-field').first().fill("Docs");
    await page.getByText("Docs pass", { exact: true }).waitFor();
    await page.evaluate(() => {
      const frames: { at: number; newTab: boolean; empty: boolean; transcript: boolean }[] = [];
      (window as unknown as { staleChatFrames: typeof frames }).staleChatFrames = frames;
      const start = performance.now();
      window.cmuxAfterPaint(() => {
        frames.push({
          at: performance.now() - start,
          newTab: Boolean(document.querySelector(".acpmux-newtab")),
          empty: Boolean(document.querySelector(".acpmux-empty")),
          transcript: document.body.innerText.includes("Docs updated."),
        });
        return performance.now() - start < 1200;
      });
    });
    await page.getByText("Docs pass", { exact: true }).click();
    await page.waitForFunction(() => {
      const frames = (window as unknown as { staleChatFrames: { at: number }[] }).staleChatFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1100;
    });
    const frames = await page.evaluate(
      () =>
        (
          window as unknown as {
            staleChatFrames: { at: number; newTab: boolean; empty: boolean; transcript: boolean }[];
          }
        ).staleChatFrames,
    );
    const final = frames.at(-1)!;
    console.log(`stale-old-chat: final frame ${JSON.stringify(final)}`);
    expect(malformedAttachConsumed).toBe(true);
    expect(final.newTab).toBe(true);
    expect(final.empty).toBe(false);
    expect(final.transcript).toBe(false);

    freshSessionId = "0190a000-0000-7000-8000-0000000000f3";
    await page.evaluate(async () => {
      const actions = (
        window as unknown as {
          cmuxAcpmuxActions?: Record<string, (params: object) => Promise<unknown>>;
        }
      ).cmuxAcpmuxActions;
      await actions?.["chat.send"]?.({ text: "Fresh recovery" });
    });
    expect(freshSessionCreated).toBe(1);
    expect(freshSessionAttached).toBe(true);
    await page.close();
  });

  // Leo 2026-10-20 ("the rendering is just not great on the first frame"): a chat shown for the
  // first time (a workspace not opened yet, a page rebuilt after hibernation) reported its first
  // paint as soon as the host answered the handshake, before acpmux attached it. The app faded in
  // an empty transcript, then the rows, title and the access chip's mode popped in. From the
  // report on, every frame draws the chat whole.
  test("a chat's first open reports its first paint once it draws whole", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
    await page.addInitScript((selector) => {
      const frames: { at: number; painted: boolean; whole: boolean; text: string }[] = [];
      (window as unknown as { openFrames: typeof frames }).openFrames = frames;
      window.cmuxAfterPaint(() => {
        const text = document.body?.innerText ?? "";
        frames.push({
          at: performance.now(),
          painted: (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt !== undefined,
          whole:
            text.includes("Retry added.") && document.querySelector(selector)?.textContent === "Bypass permissions",
          text: text.slice(0, 160).replace(/\s+/g, " "),
        });
        return performance.now() < 20_000;
      });
    }, CHIP);
    await page.goto(url(A.listed.sessionId));
    await page.getByText("Retry added.").waitFor();
    await page.waitForFunction(() => (window as { cmuxDevPaintedAt?: number }).cmuxDevPaintedAt !== undefined);
    const frames = await page.evaluate(
      () =>
        (window as unknown as { openFrames: { at: number; painted: boolean; whole: boolean; text: string }[] })
          .openFrames,
    );
    await page.close();
    const shown = frames.filter((frame) => frame.painted);
    const broken = shown.filter((frame) => !frame.whole);
    console.log(
      `open-frames: ${shown.length} frames after the first paint report, ${broken.length} not whole` +
        (broken.length ? ` (first: ${JSON.stringify(broken[0])})` : ""),
    );
    expect(shown.length).toBeGreaterThan(0);
    expect(broken).toEqual([]);
  });

  test("a reconnect keeps the chat on screen until the chat is read again", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.goto(url(A.listed.sessionId));
    await page.getByText("Retry added.").waitFor();
    const CHIP = ".acpmux-access-trigger .acpmux-mode-text";
    await page.waitForFunction(
      (selector) => document.querySelector(selector)?.textContent === "Bypass permissions",
      CHIP,
    );
    await page.evaluate((selector) => {
      const frames: { at: number; chip: string; old: boolean; text: string }[] = [];
      (window as unknown as { reconnectFrames: typeof frames }).reconnectFrames = frames;
      const start = performance.now();
      window.cmuxAfterPaint(() => {
        const text = document.body.innerText;
        frames.push({
          at: performance.now() - start,
          chip: document.querySelector(selector)?.textContent ?? "",
          old: text.includes("Retry added."),
          text: text.slice(0, 160).replace(/\s+/g, " "),
        });
        return performance.now() - start < 2000;
      });
    }, CHIP);
    // acpmux restarts: the pane's socket drops and it connects again.
    const before = attaches;
    for (const socket of sockets) socket.close(1012, "restart");
    await page.waitForFunction(() => {
      const frames = (window as unknown as { reconnectFrames: { at: number }[] }).reconnectFrames;
      return frames.length > 0 && frames.at(-1)!.at >= 1900;
    });
    const frames = await page.evaluate(
      () =>
        (window as unknown as { reconnectFrames: { at: number; chip: string; old: boolean; text: string }[] })
          .reconnectFrames,
    );
    await page.close();
    const lost = frames.filter((frame) => !frame.old || frame.chip !== "Bypass permissions");
    console.log(
      `reconnect-frames: ${frames.length} frames, ${lost.length} without the chat or its chip` +
        (lost.length
          ? ` over ${(lost.at(-1)!.at - lost[0].at).toFixed(0)} ms (first: ${JSON.stringify(lost[0])})`
          : ""),
    );
    expect(lost).toEqual([]);
    // It did connect again and read the chat (not just stay on the dropped connection's frame).
    expect(attaches).toBeGreaterThan(before);
  });
});
