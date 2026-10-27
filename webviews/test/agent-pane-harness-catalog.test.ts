// Leo 2026-10-12, on nightly-next: the Harnesses page called every harness "Not installed",
// Claude Code included. The pane's acpmux client fetches the harness list apart from the chat
// (catalog.ts), and the page drew from the client's own snapshot, whose list stays empty. The page is the pane's dev entry
// with its browser host, talking JSON-RPC to a stand-in acpmux daemon that has Claude Code.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-harness-catalog.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-harness-catalog: skipping (run `bunx playwright install chromium`)");
    describe.skip("harness catalog", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const PROJECT = "/Users/you/src/atlas";
  const VIDEO_PATH = "/Users/you/Desktop/first-chat.mov";
  const DRAFT = "Implement a todo list from this screenshot";
  type FirstRunWindow = Window & {
    cmuxWebSwap: { hold(): string | null };
    finishFirstRunImage(): void;
    finishFirstRunVideo(): void;
    firstRunVideoCalls: { src: string }[];
    firstRunChatCalls: { method: string; params: Record<string, unknown> }[];
  };
  const START = Date.UTC(2026, 9, 12, 9, 0, 0);
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/app",
    title: "App",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  const events = [
    {
      sessionId: CHAT,
      seq: 1,
      at: START,
      dir: "mux",
      kind: "user_message",
      msg: { text: "Hello" },
    },
    {
      sessionId: CHAT,
      seq: 2,
      at: START + 1000,
      dir: "in",
      kind: "agent_message_chunk",
      msg: {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "Hi there." },
          },
        },
      },
    },
  ];
  // What acpmux answered on a Mac with Claude Code on PATH (nightly-next, 2026-10-12), cut down.
  const model = (id: string, shortName: string, family: string) => ({
    id,
    name: `Claude ${shortName}`,
    shortName,
    family,
  });
  const claudeModels = [
    { id: "default", name: "Default (Claude Code's choice)" },
    model("claude-fable-5-1", "Fable 5.1", "Fable"),
    model("claude-fable-5", "Fable 5", "Fable"),
    model("claude-opus-5-5", "Opus 5.5", "Opus"),
    model("claude-opus-5", "Opus 5", "Opus"),
    model("claude-opus-4-8", "Opus 4.8", "Opus"),
    model("claude-sonnet-5-5", "Sonnet 5.5", "Sonnet"),
    model("claude-sonnet-5", "Sonnet 5", "Sonnet"),
    model("claude-haiku-5-5", "Haiku 5.5", "Haiku"),
    model("claude-haiku-4-5", "Haiku 4.5", "Haiku"),
  ];
  const harnesses = {
    harnesses: {
      claude: {
        kind: "claude-stdio",
        description: "found on PATH",
        family: "claude",
      },
    },
    families: { claude: ["claude"] },
    defaultHarness: "claude",
  };
  const models = {
    harnesses: [
      {
        harness: "claude",
        kind: "claude-stdio",
        isDefault: true,
        models: claudeModels,
      },
    ],
  };

  type DaemonState = { firstRun: boolean; installed: boolean };
  function answer(method: string, state: DaemonState, params: Record<string, unknown> = {}): unknown {
    const missing = state.firstRun && !state.installed;
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: {
            acpmux: { origin: "local", extensions: [], operations: [] },
          },
        };
      case "_acpmux/watch":
        return { sessions: state.firstRun ? [] : [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      case "_acpmux/harnesses":
        return missing ? { harnesses: {}, families: {} } : harnesses;
      case "_acpmux/models":
        return missing ? { harnesses: [] } : models;
      case "_acpmux/harness/health":
        if (params.rescan) state.installed = true;
        return { harnesses: state.installed ? [{ id: "claude", auth: "signedIn" }] : [] };
      default:
        return null;
    }
  }

  let daemon: Bun.Server<DaemonState> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`;
  };
  beforeAll(async () => {
    daemon = Bun.serve<DaemonState>({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        const firstRun = new URL(request.url).pathname === "/first-run";
        return server.upgrade(request, { data: { firstRun, installed: !firstRun } })
          ? undefined
          : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as {
            id?: number;
            method: string;
            params?: Record<string, unknown>;
          };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({
                jsonrpc: "2.0",
                id: message.id,
                result: answer(message.method, ws.data, message.params),
              }),
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
    // A cold dev server's first load can stall in CI (agent-pane-replay.test.ts): load it here,
    // again if it stalls, so the test times only the page.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("Hi there.").waitFor({ timeout: 25_000 });
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

  async function firstRunPage() {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.addInitScript(
      ({ endpoint, project }) => {
        const home = "/Users/you";
        const newTab = { kind: "agent", template: "default", cwd: home, home, projects: [] };
        Object.assign(window, {
          __cmuxNewTabContext: newTab,
          webkit: {
            messageHandlers: {
              agentSession: {
                postMessage: async ({ method, params }: { method: string; params?: Record<string, unknown> }) => {
                  let value: unknown = null;
                  switch (method.replace(/^cmux\.agent\./, "")) {
                    case "ready":
                    case "handshake":
                      value = {
                        protocolVersion: 1,
                        transport: "acpmux-websocket",
                        endpoint,
                        token: "t",
                        newSession: true,
                        newTab,
                      };
                      break;
                    case "newTab.context":
                      value = { newTab };
                      break;
                    case "project.list":
                      value = { projects: [] };
                      break;
                    case "project.browse":
                      value = { cwd: project };
                      break;
                    case "chat.attach.dropped":
                      value = { items: [{ path: "/Users/you/Desktop/first-chat.mov", folder: false }] };
                      break;
                    case "video.info": {
                      const calls = ((
                        window as unknown as { firstRunVideoCalls?: { src: string }[] }
                      ).firstRunVideoCalls ??= []);
                      calls.push({ src: String(params?.src ?? "") });
                      value = await new Promise((resolve) =>
                        Object.assign(window, {
                          finishFirstRunVideo: () =>
                            resolve({
                              durationMs: 42_400,
                              width: 1_920,
                              height: 1_080,
                              poster: "data:image/jpeg;base64,/9j/AA==",
                              frames: [{ atMs: 5_300, data: "/9j/AA==" }],
                            }),
                        }),
                      );
                      break;
                    }
                    case "shell.run":
                      value = { id: "install-claude" };
                      break;
                    case "shell.read":
                      value = { exit: { code: 0 } };
                      break;
                  }
                  return { ok: true, value };
                },
              },
            },
          },
        });
      },
      { endpoint: `ws://127.0.0.1:${daemon!.port}/first-run`, project: PROJECT },
    );
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/`);
    await page.locator(".nt-field").waitFor();
    // Wait for the actual no-harness chip; the page may mount before the catalog arrives.
    await page.locator(".acpmux-add-harness").waitFor();
    // An inherited home folder is not a saved project: the clean card must still offer Browse.
    expect(await page.locator('[data-action="browse-project"]').isVisible()).toBe(true);
    return page;
  }

  async function prepareDraft(page: Page, noProject: boolean, pendingImage = false) {
    await page
      .locator(noProject ? '.nt-env .nt-stage-row[aria-pressed="false"]' : '[data-action="browse-project"]')
      .click();
    await page.locator('.nt-env .nt-stage-row[aria-pressed="true"]').waitFor();
    const field = page.locator(".nt-field");
    await field.fill(DRAFT);
    await field.evaluate(async (target, pendingImage) => {
      if (pendingImage) {
        const post = Worker.prototype.postMessage;
        Worker.prototype.postMessage = function (message) {
          if (message?.kind !== "prepare") return post.call(this, message);
          Worker.prototype.postMessage = post;
          Object.assign(window, { finishFirstRunImage: () => post.call(this, message) });
        };
      }
      const canvas = document.createElement("canvas");
      canvas.width = 8;
      canvas.height = 8;
      canvas.getContext("2d")!.fillRect(0, 0, 8, 8);
      const blob = await new Promise<Blob>((resolve) => canvas.toBlob((png) => resolve(png!), "image/png"));
      const data = new DataTransfer();
      data.items.add(new File([blob], "first-chat.png", { type: "image/png" }));
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    }, pendingImage);
    const image = page.locator(".acpmux-attachment-image img");
    if (pendingImage)
      await page.waitForFunction(() => typeof (window as unknown as FirstRunWindow).finishFirstRunImage === "function");
    else await image.waitFor();
    return { field, image };
  }

  async function preparePendingVideo(page: Page, noProject: boolean) {
    await page
      .locator(noProject ? '.nt-env .nt-stage-row[aria-pressed="false"]' : '[data-action="browse-project"]')
      .click();
    await page.locator('.nt-env .nt-stage-row[aria-pressed="true"]').waitFor();
    const field = page.locator(".nt-field");
    await field.fill(DRAFT);
    await field.evaluate((target) => {
      const data = new DataTransfer();
      data.items.add(new File([new Uint8Array([0x00, 0x01, 0x02])], "first-chat.mov", { type: "video/quicktime" }));
      target.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
    });
    await page.locator(".acpmux-attachment-link-name").filter({ hasText: "first-chat.mov" }).waitFor();
    await page.waitForFunction(() => typeof (window as unknown as FirstRunWindow).finishFirstRunVideo === "function");
  }

  test.each(["", "Implement a todo list"])("first-run Return opens setup and returns to draft %j", async (draft) => {
    const page = await firstRunPage();
    try {
      const field = page.locator(".nt-field");
      if (draft) await field.fill(draft);
      await field.press("Enter");
      await page.locator(".acpmux-harnesses-close").waitFor();
      expect(await field.isVisible()).toBe(false);
      await page.locator(".acpmux-harnesses-close").click();
      await field.waitFor();
      expect(await field.inputValue()).toBe(draft);
    } finally {
      await page.close();
    }
  });

  test("first-run New chat setup preserves the typed draft, image and no-project choice", async () => {
    const page = await firstRunPage();
    try {
      const { field, image } = await prepareDraft(page, true);
      const source = await image.getAttribute("src");
      expect(source).toBeTruthy();
      await page.locator('[data-create="chat"]').click();
      await page.locator(".acpmux-harnesses-close").waitFor();
      expect(await field.isVisible()).toBe(false);
      expect(await image.isVisible()).toBe(false);
      expect(await page.evaluate(() => (window as unknown as FirstRunWindow).cmuxWebSwap.hold())).toMatch(/^newtab\./);
      await page.locator(".acpmux-harnesses-close").click();
      await field.waitFor();
      expect(await field.inputValue()).toBe(DRAFT);
      expect(await image.isVisible()).toBe(true);
      expect(await image.getAttribute("src")).toBe(source);
      expect(await page.locator('.nt-env .nt-stage-row[aria-pressed="true"]').count()).toBe(1);
      expect(await page.locator('[data-action="browse-project"]').count()).toBe(0);
    } finally {
      await page.close();
    }
  });

  test("first-run Start Chat waits for a revealed video read before sending the draft", async () => {
    const page = await firstRunPage();
    try {
      await preparePendingVideo(page, true);
      await page.locator('[data-create="chat"]').click();
      const claude = page.locator('[data-harness-row="claude"]');
      await page.locator('[data-harness-row="claude"][data-harness-status="notInstalled"]').waitFor();
      await claude.locator(".acpmux-harness-action").click();
      await page.locator('[data-harness-row="claude"][data-harness-status="ready"]').waitFor();
      await page.evaluate(() => {
        const calls: { method: string; params: Record<string, unknown> }[] = [];
        Object.assign(window, { firstRunChatCalls: calls });
        for (const method of ["chat.new", "chat.send"])
          window.cmuxAcpmuxActions![method] = async (params) => {
            calls.push({ method, params });
            return "first-chat";
          };
      });
      await claude.locator(".acpmux-harness-action").click();

      // Setup hides and then reveals the New Tab Activity. The first video.info is interrupted;
      // the second is the read that the resumed Start Chat must wait for.
      await page.waitForFunction(() => (window as unknown as FirstRunWindow).firstRunVideoCalls?.length === 2);
      expect(await page.evaluate(() => (window as unknown as FirstRunWindow).firstRunChatCalls)).toEqual([]);
      await page.evaluate(() => (window as unknown as FirstRunWindow).finishFirstRunVideo());
      await page.waitForFunction(() =>
        (window as unknown as FirstRunWindow).firstRunChatCalls.some((call) => call.method === "chat.send"),
      );

      const calls = await page.evaluate(() => (window as unknown as FirstRunWindow).firstRunChatCalls);
      expect(calls.map((call) => call.method)).toEqual(["chat.new", "chat.send"]);
      expect(calls[0]!.params).toEqual({ harness: "claude", noProject: true });
      expect(calls[1]!.params).toEqual({
        text: DRAFT,
        attachments: [
          expect.objectContaining({
            kind: "link",
            name: "first-chat.mov",
            mimeType: "video/quicktime",
            path: VIDEO_PATH,
            video: expect.objectContaining({ durationMs: 42_400, width: 1_920, height: 1_080 }),
          }),
        ],
      });
    } finally {
      await page.close();
    }
  });

  const starts = [
    [false, false, false],
    [true, false, false],
    [false, true, false],
    [false, false, true],
  ];
  test.each(starts)(
    "Start Chat keeps project choice %s and pending image %s",
    async (noProject, pendingImage, addHarness) => {
      const page = await firstRunPage();
      try {
        const { field } = await prepareDraft(page, noProject, pendingImage);
        await page.locator(addHarness ? ".acpmux-add-harness" : '[data-create="chat"]').click();
        const claude = page.locator('[data-harness-row="claude"]');
        await page.locator('[data-harness-row="claude"][data-harness-status="notInstalled"]').waitFor();
        await claude.locator(".acpmux-harness-action").click();
        await page.locator('[data-harness-row="claude"][data-harness-status="ready"]').waitFor();
        // Observe the App's actual action boundary, without starting a real agent process.
        await page.evaluate(() => {
          const calls: { method: string; params: Record<string, unknown> }[] = [];
          Object.assign(window, { firstRunChatCalls: calls });
          for (const method of ["chat.new", "chat.send"])
            window.cmuxAcpmuxActions![method] = async (params) => {
              calls.push({ method, params });
              return "first-chat";
            };
        });
        await claude.locator(".acpmux-harness-action").click();
        if (pendingImage) {
          await field.waitFor();
          expect(await page.evaluate(() => (window as unknown as FirstRunWindow).firstRunChatCalls)).toEqual([]);
          await page.evaluate(() => (window as unknown as FirstRunWindow).finishFirstRunImage());
        }
        await page.waitForFunction(() =>
          (window as unknown as FirstRunWindow).firstRunChatCalls.some((call) => call.method === "chat.send"),
        );
        const calls = await page.evaluate(() => (window as unknown as FirstRunWindow).firstRunChatCalls);
        expect(calls.map((call) => call.method)).toEqual(["chat.new", "chat.send"]);
        expect(calls[0]!.params).toEqual(
          noProject ? { harness: "claude", noProject: true } : { harness: "claude", cwd: PROJECT },
        );
        expect(calls[1]!.params).toEqual({
          text: DRAFT,
          attachments: [
            expect.objectContaining({
              kind: "image",
              name: "first-chat.png",
              mimeType: "image/png",
              data: expect.stringMatching(/.+/),
            }),
          ],
        });
      } finally {
        await page.close();
      }
    },
  );

  test("the Harnesses page has Claude Code ready", async () => {
    const page = await browser!.newPage({
      viewport: { width: 900, height: 760 },
    });
    await page.goto(url());
    await page.getByText("Hi there.").waitFor();
    // The full model picker's last row, Add harness…, opens the page in place. This chat has a
    // message, so its picker offers no other harness unless Debug Settings' started-chat harness
    // switch is on. The model button opens its compact menu (Leo 2026-10-20); Cmd-Ctrl-M opens the
    // full picker, as More models does.
    await page.evaluate(() => window.cmuxAcpmuxComposer?.({ harnessSwitch: true }));
    await page.locator(".acpmux-model .acpmux-picker-button").waitFor();
    await page.keyboard.press("Meta+Control+m");
    await page.locator(".acpmux-mp-add-harness").click();
    const claude = page.locator("[data-harness-row]").filter({ hasText: "Claude Code" });
    await claude.waitFor();
    expect(await claude.getAttribute("data-harness-status")).toBe("ready");
    await page.close();
  });
});
