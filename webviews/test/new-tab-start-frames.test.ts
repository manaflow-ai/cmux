// l10n-allow-file: test fixture prompts and harness names, not shipped UI.
// A new chat started from New Tab never draws the agent pane's older empty-chat hero ("What should
// we build?", its folder and machine row and the Needs you list over a docked composer). Leo,
// 2026-11-17, on his NIGHTLY after a start failed: "this is an old ass deprecated view. this should
// not have been shown." and "the layout shift when starting a new chat is prob caused by that
// deprecated-ass screen maybe?".
//
// The real agent pane (the dev entry) in Chromium, with a stand-in host and a stand-in acpmux daemon
// whose `session/new` answers late (a loaded Mac). Every painted frame from Return until the chat
// settles is classified: the New Tab page, the started chat (the sent prompt in its transcript), or the
// old hero (`.acpmux-empty` with no chat). No frame may be the old hero, whether the start succeeds
// or fails.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/new-tab-start-frames.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("new-tab-start-frames.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("new-tab-start-frames: skipping (run `bunx playwright install chromium`)");
    describe.skip("new tab start frames", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const HOME = "/Users/you";
  const PROMPT = "what is one plus one";
  const FRESH = "0190a000-0000-7000-8000-0000000000a1";
  /// How long acpmux takes to give a harness session on a loaded Mac.
  const START_MS = 900;
  const claudeModels = [{ id: "claude-opus-5-5", name: "Claude Opus 5.5", shortName: "Opus 5.5", family: "Opus" }];
  const catalog = [{ id: "claude", name: "Claude Code", family: "claude", models: claudeModels }];

  function answer(method: string, params: Record<string, unknown>, starts: boolean): unknown {
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
        // A start that gives no session (the case the pane names "did not start a session").
        return starts ? { sessionId: FRESH } : {};
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
        const starts = new URL(request.url).searchParams.get("starts") !== "0";
        return server.upgrade(request, { data: { starts } }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        async message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, unknown> };
          if (message.id === undefined) return;
          // fixed-wait: a slow session/new is the state under test, not a wait for one
          if (message.method === "session/new") await Bun.sleep(START_MS);
          const { starts } = ws.data as { starts: boolean };
          ws.send(
            JSON.stringify({
              jsonrpc: "2.0",
              id: message.id,
              result: answer(message.method, message.params ?? {}, starts),
            }),
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

  type Frame = { at: number; newTab: boolean; hero: boolean; chat: boolean; failed: boolean; text: string };

  /// Types PROMPT on a New Tab page (`template`: the New Tab screen, or the Classic page) and presses
  /// Return; records every painted frame for `ms`.
  async function startFromNewTab(starts: boolean, ms: number, template = "minimal", prompt = PROMPT): Promise<Frame[]> {
    const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
    await installPaintedFrames(page);
    const endpoint = `ws://127.0.0.1:${daemon!.port}/?starts=${starts ? 1 : 0}`;
    const context = {
      kind: "agent",
      hotkeys: {},
      home: HOME,
      projects: [],
      host: "cosmic-gray",
      template,
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
    const field = page
      .locator('.nt-field [contenteditable="true"], .acpmux-newtab-field [contenteditable="true"]')
      .first();
    await field.waitFor({ timeout: 30_000 });
    // The harness row has its pick before the send (the New Tab page's own first-frame contract).
    await page.waitForFunction(
      () => document.querySelector(".nt-composer, .acpmux-newtab")?.textContent?.includes("Opus"),
      null,
      {
        timeout: 30_000,
      },
    );
    if (prompt) await field.fill(prompt);
    await page.evaluate(
      ({ ms, prompt }) => {
        const frames: Frame[] = [];
        (window as unknown as { startFrames: Frame[] }).startFrames = frames;
        const start = performance.now();
        window.cmuxAfterPaint(() => {
          const empty = document.querySelector(".acpmux-empty:not(.acpmux-unavailable)");
          const transcript = document.querySelector(".acpmux-transcript, .acpmux-rows, [data-row-id]");
          frames.push({
            at: performance.now() - start,
            newTab: Boolean(document.querySelector(".nt-composer, .acpmux-newtab")),
            hero: Boolean(empty),
            chat: Boolean(transcript?.textContent?.includes(prompt)),
            // New Tab's own failure line (the screen's StartFailure, the Classic page's).
            failed: Boolean(document.querySelector(".acpmux-newtab-failed, .acpmux-start-failure")),
            text: document.body.innerText.slice(0, 200).replace(/\s+/g, " "),
          });
          return performance.now() - start < ms;
        });
      },
      { ms, prompt: prompt || PROMPT },
    );
    await field.press("Enter");
    await page.waitForFunction(
      (ms) => {
        const frames = (window as unknown as { startFrames: { at: number }[] }).startFrames;
        return frames.length > 0 && frames.at(-1)!.at >= ms - 100;
      },
      ms,
      { timeout: ms + 30_000 },
    );
    const frames = await page.evaluate(() => (window as unknown as { startFrames: Frame[] }).startFrames);
    await page.close();
    return frames;
  }

  const report = (name: string, frames: Frame[]) => {
    const heroes = frames.filter((frame) => frame.hero && !frame.chat);
    console.log(
      `${name}: ${frames.length} frames, ${heroes.length} old-hero frames` +
        (heroes.length ? ` (first at ${heroes[0].at.toFixed(0)} ms: ${JSON.stringify(heroes[0].text)})` : "") +
        `; last: ${JSON.stringify(frames.at(-1)?.text ?? "")}`,
    );
    return heroes;
  };

  test("a new chat started from New Tab never draws the old empty-chat hero", async () => {
    const frames = await startFromNewTab(true, START_MS + 1_500);
    expect(report("start", frames)).toEqual([]);
  });

  test("a new chat whose start fails stays on New Tab, never on the old empty-chat hero", async () => {
    const frames = await startFromNewTab(false, START_MS + 2_000);
    expect(report("failed start", frames)).toEqual([]);
    // The failure is said in place, on New Tab, with the prompt kept.
    expect(frames.at(-1)?.newTab).toBe(true);
  });

  test("a chat the Classic New Tab page starts that fails comes back to the page, never the old hero", async () => {
    const frames = await startFromNewTab(false, START_MS + 2_000, "classic");
    expect(report("classic failed start", frames)).toEqual([]);
    expect(frames.at(-1)?.newTab).toBe(true);
    expect(frames.at(-1)?.failed).toBe(true);
    // The prompt is back in the page's field.
    expect(frames.at(-1)?.text).toContain(PROMPT);
  });

  test("a chat the Classic New Tab page starts never draws the old hero", async () => {
    const frames = await startFromNewTab(true, START_MS + 1_500, "classic");
    expect(report("classic start", frames)).toEqual([]);
  });

  test("a blank Return on the Classic page whose start fails comes back to the page with its failure", async () => {
    // A blank Return keeps its immediate move to the chat view (it has no prompt to show a
    // switch with). The settled start must not leave the page a second time after the failure
    // brought it back: that left the old hero up with no failure card.
    const frames = await startFromNewTab(false, START_MS + 2_000, "classic", "");
    report("classic blank failed start", frames);
    expect(frames.at(-1)?.newTab).toBe(true);
    expect(frames.at(-1)?.failed).toBe(true);
  });
});
