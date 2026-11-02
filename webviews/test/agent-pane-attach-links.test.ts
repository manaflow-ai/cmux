// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// Sources' + in the chat's summary attaches files or folders on this computer (cx-thur3):
// - it asks the host's panel (`chat.attach.choose`), and each file or folder it picked waits in
//   the composer as a chip named for it, a folder's with a trailing slash;
// - the next prompt carries them as ACP resource_link blocks (file:// URIs), after its text, so
//   any harness reads them where they are;
// - a chat on another machine (a peer, or a host not marked local) has no +: this computer's files
//   are not that machine's.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux;
// the host's panel is a stand-in that answers with two picks.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-attach-links.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-attach-links: skipping (run `bunx playwright install chromium`)");
    describe.skip("attach links", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000e2";
  const START = Date.UTC(2026, 9, 14, 9, 0, 0);
  const steps: [dir: string, kind: string, msg: Record<string, unknown>][] = [
    ["mux", "user_message", { text: "Tidy the release notes" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "agent_message_chunk",
      {
        method: "session/update",
        params: {
          sessionId: "agent-1",
          update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The notes are tidy." } },
        },
      },
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: START + index * 1000,
    dir,
    kind,
    msg,
  }));
  let session: Record<string, unknown> = {};
  const local = {
    sessionId: CHAT,
    cwd: "/home/dev/notes",
    title: "Release notes",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };
  session = local;
  const prompts: unknown[] = [];
  /// Runs on the next `session/prompt` the daemon takes.
  let prompted = () => {};

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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { prompt?: unknown } };
          if (message.method === "session/prompt") {
            prompts.push(message.params?.prompt);
            prompted();
          }
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
    // again if it stalls, so the tests time only the panel.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url());
        await warm.getByText("The notes are tidy.").waitFor({ timeout: 25_000 });
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

  const open = async (page: Page) => {
    // The page replaces its actions map as a chat starts (App.tsx `chat.send`): keep the stand-in
    // panel in every map it sets.
    await page.addInitScript(() => {
      const panel = {
        "chat.attach.choose": async () => ({
          items: [
            { path: "/home/dev/notes/drafts", folder: true },
            { path: "/home/dev/notes/release notes.md", folder: false },
          ],
        }),
      };
      let actions: Record<string, unknown> = { ...panel };
      Object.defineProperty(window, "cmuxAcpmuxActions", {
        configurable: true,
        get: () => actions,
        set: (next: Record<string, unknown> | undefined) => {
          actions = { ...next, ...panel };
        },
      });
    });
    await page.goto(url());
    await page.getByText("The notes are tidy.").waitFor();
    // A chat with no summary content keeps the card closed until the header's button opens it.
    await page.getByRole("button", { name: "Chat summary" }).click();
    await page.getByRole("complementary", { name: "Chat summary" }).waitFor({ timeout: 5_000 });
  };
  const attach = (page: Page) => page.getByRole("button", { name: "Attach files or folders" });

  test("Sources' + puts the picked files and folders in the composer, and the prompt links them", async () => {
    session = local;
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await attach(page).click();
    const composer = page.locator(".acpmux-composer");
    await composer.getByText("drafts/").waitFor({ timeout: 5_000 });
    await composer.getByText("release notes.md").waitFor({ timeout: 5_000 });
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("Compare these");
    prompts.length = 0;
    const sent = new Promise<void>((resolve) => (prompted = resolve));
    await page.keyboard.press("Enter");
    await sent;
    // The picked links went in the prompt at its caret, before the words typed after them, and the
    // prompt goes in that order.
    expect(prompts[0]).toEqual([
      { type: "resource_link", uri: "file:///home/dev/notes/drafts", name: "drafts/" },
      { type: "resource_link", uri: "file:///home/dev/notes/release%20notes.md", name: "release notes.md" },
      { type: "text", text: "Compare these" },
    ]);
    await context.close();
  });

  test("a slash command with instructions goes as a prompt and keeps its attached files", async () => {
    session = local;
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    await attach(page).click();
    const composer = page.locator(".acpmux-composer");
    await composer.getByText("release notes.md").waitFor({ timeout: 5_000 });
    await page.locator(".acpmux-composer-prompt").click();
    await page.keyboard.type("/plan compare these");
    prompts.length = 0;
    const sent = new Promise<void>((resolve) => (prompted = resolve));
    await page.keyboard.press("Enter");
    await sent;
    expect(prompts[0]).toEqual([
      { type: "text", text: "/plan compare these" },
      { type: "resource_link", uri: "file:///home/dev/notes/drafts", name: "drafts/" },
      { type: "resource_link", uri: "file:///home/dev/notes/release%20notes.md", name: "release notes.md" },
    ]);
    await context.close();
  });

  test("a chat on another machine has no +", async () => {
    session = { ...local, peer: "devbox" };
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    expect(await attach(page).count()).toBe(0);
    await context.close();
    session = local;
  });

  test("a chat whose host is set and not marked local has no +", async () => {
    session = { ...local, host: "build-box" };
    const context = await browser!.newContext({ viewport: { width: 1280, height: 800 } });
    const page = await context.newPage();
    await open(page);
    expect(await attach(page).count()).toBe(0);
    await context.close();
    session = local;
  });
});
