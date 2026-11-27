// l10n-allow-file: test fixture prompts and tool titles, not shipped UI.
// Two permission asks can wait at once: acpmux keeps every pending ask (hub/permissions.rs
// `state.pending`) and only groupable tool asks join a permission group, so a question and a
// command, or two subagents' asks, can both wait on the person. The pane showed only the latest:
// a second ask replaced the first card, and once the second was answered the first had no card
// at all while its agent still waited for it. Asks now wait in line, oldest first, the card says
// how many more wait, and answering one shows the next.
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-permission-queue.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-permission-queue: skipping (run `bunx playwright install chromium`)");
    describe.skip("permission queue", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const LIVE = "0190a000-0000-7000-8000-0000000000e1";
  const REOPENED = "0190a000-0000-7000-8000-0000000000e2";
  const START = Date.UTC(2026, 9, 20, 9, 0, 0);
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const ask = (permissionId: string, toolCallId: string, title: string, command: string): Step => [
    "mux",
    "permission_request",
    {
      permissionId,
      request: {
        toolCall: { toolCallId, title, kind: "execute", rawInput: { command } },
        options: [
          { optionId: "allow", name: "Allow", kind: "allow_once" },
          { optionId: "deny", name: "Deny", kind: "reject_once" },
        ],
      },
    },
  ];
  const first = ask("p1", "t1", "Run npm test", "npm test");
  const second = ask("p2", "t2", "Run git push", "git push");
  const steps: Step[] = [
    ["mux", "user_message", { text: "Test and push the branch" }],
    ["mux", "turn_started", {}],
    first,
    second,
  ];
  const record = (sessionId: string, [dir, kind, msg]: Step, seq: number) => ({
    sessionId,
    seq,
    at: START + seq * 1000,
    dir,
    kind,
    msg,
  });
  const events = (sessionId: string) => steps.map((step, index) => record(sessionId, step, index + 1));
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    title: "Test and push",
    harness: "claude",
    family: "claude",
    status: "running",
    turnCount: 1,
    updatedAt: START,
  });

  /// The answers each page sent, as `_acpmux/permission_respond` params.
  const responses: Record<string, unknown>[] = [];
  /// Called each time the pane answers an ask.
  let onResponse: (() => void) | undefined;
  /// Resolves once acpmux has heard an answer.
  const answered = () =>
    new Promise<void>((resolve) => {
      if (responses.length > 0) return resolve();
      onResponse = () => {
        onResponse = undefined;
        resolve();
      };
    });
  function answer(method: string, params: Record<string, any> = {}): unknown {
    const id = params.sessionId === REOPENED ? REOPENED : LIVE;
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(LIVE), session(REOPENED)] };
      case "_acpmux/attach": {
        const attached = { session: session(id), lastSeq: steps.length, events: events(id) };
        // acpmux lists the asks still waiting on the attached session (`hub/views.rs` `pending`),
        // in no particular order (a hash map's).
        if (id === REOPENED) return { ...attached, session: { ...session(id), pending: [second[2], first[2]] } };
        return attached;
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: steps.length };
      case "_acpmux/permission_respond":
        responses.push(params);
        onResponse?.();
        return {};
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const sockets = new Set<{ send(data: string): void }>();
  let liveSeq = steps.length;
  /// Sends a live event of `sessionId` to every page attached now.
  const push = (sessionId: string, step: Step) => {
    const event = record(sessionId, step, ++liveSeq);
    for (const ws of sockets) ws.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
  };
  const url = (sessionId: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${sessionId}`;
  };
  const open = async (sessionId: string) => {
    sockets.clear();
    liveSeq = steps.length;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(sessionId));
    await page.getByText("Test and push the branch").waitFor({ timeout: 25_000 });
    return page;
  };
  const card = (page: Page) => page.locator(".acpmux-permission-ask");
  /// The card's text once it shows `text` (fails after 10 s).
  const cardShowing = async (page: Page, text: string) => {
    const shown = card(page).filter({ hasText: text }).first();
    await shown.waitFor({ timeout: 10_000 });
    return shown.textContent();
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
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
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      try {
        await (await open(LIVE)).close();
        break;
      } catch (error) {
        if (attempt === 3) throw error;
      }
    }
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  test("the oldest ask shows first, says one more waits, and the next shows once it is answered", async () => {
    const page = await open(LIVE);
    await card(page).waitFor();
    expect(await card(page).textContent()).toContain("npm test");
    expect(await card(page).textContent()).toContain("1 more waiting");
    responses.length = 0;
    await card(page).getByRole("button", { name: "Allow once" }).click();
    await answered();
    expect(responses.map((params) => params.permissionId)).toEqual(["p1"]);
    push(LIVE, ["mux", "permission_decision", { permissionId: "p1", optionId: "allow" }]);
    const next = await cardShowing(page, "git push");
    expect(next).not.toContain("more waiting");
    push(LIVE, ["mux", "permission_decision", { permissionId: "p2", optionId: "allow" }]);
    await card(page).first().waitFor({ state: "detached", timeout: 10_000 });
    await page.close();
  });

  test("a reopened chat lists every ask acpmux still holds", async () => {
    const page = await open(REOPENED);
    await card(page).waitFor();
    expect(await card(page).textContent()).toContain("npm test");
    expect(await card(page).textContent()).toContain("1 more waiting");
    push(REOPENED, ["mux", "permission_decision", { permissionId: "p1", optionId: "allow" }]);
    expect(await cardShowing(page, "git push")).toContain("git push");
    await page.close();
  });
});
