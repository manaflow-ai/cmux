// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A new chat started from New Tab draws no layout jump from the composer at rest to the first turn.
// Leo, 2026-11-17: "i also ran into this error jsut now when starting a chat! i wonder how this
// regressed and how we can prevent this (and what happened?)" and "the layout shift when starting a
// new chat is prob caused by that deprecated-ass screen maybe?".
//
// The real agent pane (the dev entry) in Chromium, with a stand-in host and a stand-in acpmux daemon
// whose `session/new` answers late (a loaded Mac). Every painted frame from Return until the chat
// settles records the boxes of the composer, its field and the sent prompt's row
// (helpers/layoutShift.ts); none may jump between two frames in a row.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-chat-start-no-shift.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import {
  describeJumps,
  describeLayoutShifts,
  describeTeleport,
  expectNoJumpAt,
  expectNoLayoutShift,
  expectNoTeleport,
  findJumpsAt,
  findLayoutShifts,
  findTeleport,
  installLayoutBoxes,
  type LayoutFrame,
  type TeleportMeasure,
  type TeleportOptions,
} from "./helpers/layoutShift";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-chat-start-no-shift.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-chat-start-no-shift: skipping (run `bunx playwright install chromium`)");
    describe.skip("new chat start no shift", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const PROMPT = "what is one plus one";
  const FRESH = "0190a000-0000-7000-8000-0000000000b2";
  /// How long acpmux takes to give a harness session on a loaded Mac.
  const START_MS = 900;
  const claudeModels = [{ id: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5", family: "Opus" }];
  const catalog = [{ id: "claude", name: "Claude Code", family: "claude", models: claudeModels }];
  /// The parts whose boxes each frame records. `box` and `typing` are the composer and its field the
  /// person types in, whichever surface draws them (New Tab's, then the chat's): one part each, so a
  /// handover that puts the chat's somewhere else in one frame reads as the jump it is.
  const PARTS: Record<string, string> = {
    box: ".nt-composer, .acpmux-composer",
    typing: '.nt-field [contenteditable="true"], .acpmux-composer [contenteditable="true"]',
    /// The glass card the person sees around the field: New Tab's `.nt-box`, the chat's composer box.
    card: ".nt-box, .acpmux-composer > .acpmux-composer-box",
    composer: ".acpmux-composer",
    field: '.acpmux-composer [contenteditable="true"]',
    newTabComposer: ".nt-composer",
    prompt: "[data-row-id]",
  };
  const TEXT: Record<string, string> = { prompt: PROMPT };

  function answer(method: string, params: Record<string, unknown>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
      case "_acpmux/sessions":
        return { sessions: [] };
      case "_acpmux/harnesses":
        return {
          harnesses: { claude: { kind: "claude-stdio", family: "claude" } },
          families: { claude: ["claude"] },
          defaultHarness: "claude",
        };
      case "_acpmux/models":
        return { harnesses: [{ harness: "claude", kind: "claude-stdio", isDefault: true, models: claudeModels }] };
      case "_acpmux/start_mode":
        return {
          harness: "claude",
          modeId: "bypassPermissions",
          name: "Bypass permissions",
          level: "fullAccess",
          source: "default",
        };
      case "session/new":
        return { sessionId: FRESH };
      case "_acpmux/attach":
        if (String(params.sessionId) !== FRESH) return null;
        return {
          session: {
            sessionId: FRESH,
            cwd: HOME,
            title: "New chat",
            harness: "claude",
            family: "claude",
            model: "claude-opus-5-5",
            status: "idle",
            turnCount: 0,
            modes: {
              currentModeId: "bypassPermissions",
              availableModes: [{ id: "bypassPermissions", name: "Bypass permissions" }],
            },
          },
          lastSeq: 0,
          events: [],
        };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      case "session/prompt":
        return { stopReason: "end_turn" };
      default:
        return null;
    }
  }

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
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id === undefined) return;
          // fixed-wait: a slow session/new is the state under test, not a wait for one
          if (message.method === "session/new") await Bun.sleep(START_MS);
          ws.send(
            JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
          );
        },
      },
    });
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.acpmux-pane.mjs"),
      server: { port: 0, host: "127.0.0.1", strictPort: false, watch: { ignored: () => true } },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    void daemon?.stop(true);
  });

  /// Types PROMPT on a New Tab page, presses Return, and records the parts' boxes on every painted
  /// frame for `ms`, starting with the frame at rest before Return.
  async function startFromNewTab(ms: number): Promise<LayoutFrame[]> {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    await installPaintedFrames(page);
    await installLayoutBoxes(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    const context = {
      kind: "agent",
      hotkeys: {},
      home: HOME,
      projects: [],
      host: "cosmic-gray",
      template: "minimal",
      lastPicks: { global: { harness: "claude", model: "claude-opus-5-5" }, folders: [] },
    };
    await page.addInitScript(
      ({ endpoint, context, catalog }) => {
        const w = window as unknown as Record<string, unknown>;
        w.__cmuxNewTabContext = context;
        localStorage.setItem("cmux.acpmux.harnessCatalog.v1", JSON.stringify({ catalog, at: Date.now() - 60_000 }));
        const reply = (value: unknown) => Promise.resolve({ ok: true, value });
        w.webkit = {
          messageHandlers: {
            agentSession: {
              postMessage: (request: { method: string }) => {
                switch (request.method) {
                  case "ready":
                    return reply({
                      protocolVersion: 1,
                      transport: "acpmux-websocket",
                      endpoint,
                      token: "t",
                      newSession: true,
                      newTab: context,
                      machineName: "cosmic-gray",
                    });
                  case "newTab.context":
                    return reply({ newTab: context });
                  case "project.list":
                    return reply({ projects: [] });
                  case "transport.gesture":
                    return reply({ ticket: "gesture" });
                  default:
                    return reply(null);
                }
              },
            },
          },
        };
      },
      { endpoint, context, catalog },
    );
    await page.goto(`http://127.0.0.1:${(vite!.httpServer!.address() as { port: number }).port}/`);
    const field = page.locator('.nt-field [contenteditable="true"]').first();
    await field.waitFor({ timeout: 30_000 });
    await page.waitForFunction(() => document.querySelector(".nt-composer")?.textContent?.includes("Opus"), null, {
      timeout: 30_000,
    });
    await field.fill(PROMPT);
    await page.evaluate(
      ({ ms, parts, text }) => {
        const w = window as unknown as {
          startFrames: LayoutFrame[];
          cmuxReadLayoutBoxes: (parts: Record<string, string>, text: Record<string, string>) => LayoutFrame["boxes"];
        };
        const frames: LayoutFrame[] = [];
        w.startFrames = frames;
        const start = performance.now();
        frames.push({ at: 0, boxes: w.cmuxReadLayoutBoxes(parts, text) });
        window.cmuxAfterPaint(() => {
          frames.push({ at: performance.now() - start, boxes: w.cmuxReadLayoutBoxes(parts, text) });
          return performance.now() - start < ms;
        });
      },
      { ms, parts: PARTS, text: TEXT },
    );
    await field.press("Enter");
    await page.waitForFunction(
      (ms) => {
        const frames = (window as unknown as { startFrames: { at: number }[] }).startFrames;
        return frames.length > 1 && frames.at(-1)!.at >= ms - 100;
      },
      ms,
      { timeout: ms + 30_000 },
    );
    const frames = await page.evaluate(() => (window as unknown as { startFrames: LayoutFrame[] }).startFrames);
    await page.close();
    return frames;
  }

  test("a new chat started from New Tab keeps the composer and the sent prompt still, frame to frame", async () => {
    const frames = await startFromNewTab(START_MS + 1_500);
    // Every frame where a part's box changed, so a failure names what moved and when.
    let last = "";
    for (const [index, frame] of frames.entries()) {
      const now = JSON.stringify(frame.boxes);
      if (now !== last) console.log(`frame ${index} at ${frame.at.toFixed(0)} ms: ${now}`);
      last = now;
    }
    console.log(describeLayoutShifts(findLayoutShifts(frames, Object.keys(PARTS), 1)).join("\n") || "no shifts");
    // The field's offset inside the card the person sees.
    const fieldInCard = (frame: LayoutFrame) =>
      frame.boxes.typing && frame.boxes.card ? frame.boxes.typing.y - frame.boxes.card.y : undefined;
    const fieldLeftInCard = (frame: LayoutFrame) =>
      frame.boxes.typing && frame.boxes.card ? frame.boxes.typing.x - frame.boxes.card.x : undefined;
    const checks: [string, TeleportOptions][] = [
      ["box", {}],
      ["typing", {}],
      ["card", { measure: "top" }],
      ["card", { measure: "left" }],
      ["card", { measure: "width" }],
      ["card", { measure: "height" }],
      ["fieldInCard", { measure: fieldInCard }],
      ["fieldLeftInCard", { measure: fieldLeftInCard }],
    ];
    for (const [part, options] of checks)
      console.log(describeTeleport(findTeleport(frames, part, options)).join("\n") || `${part}: no teleport`);
    // The frame where the chat's composer takes over from New Tab's draws the card, its size and the
    // field where New Tab left them: the handover itself moves nothing.
    const handover = frames.findIndex(
      (frame, index) => index > 0 && frame.boxes.composer && !frame.boxes.newTabComposer,
    );
    const atHandover: [string, TeleportMeasure][] = [
      ["card", "top"],
      ["card", "left"],
      ["card", "width"],
      ["card", "height"],
      ["typing", "top"],
      ["typing", "left"],
      ["fieldInCard", fieldInCard],
      ["fieldLeftInCard", fieldLeftInCard],
    ];
    console.log(
      describeJumps(findJumpsAt(frames, handover, atHandover, 1.5)).join("\n") || `handover frame ${handover}: no jump`,
    );
    // The box, its card and its field go from New Tab's place and size to the dock's by moving, not
    // in one frame (Leo, 2026-11-17: "chats settle with no unnecessary layout shifts after they start").
    expect(handover).toBeGreaterThan(0);
    expectNoJumpAt(frames, handover, atHandover, 1.5);
    for (const [part, options] of checks) expectNoTeleport(frames, part, options);
    // The sent prompt's row never jumps once it drew.
    expectNoLayoutShift(frames, ["prompt"], 1);
  });
});
