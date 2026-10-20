// l10n-allow-file: test fixture prompts and subagent names, not shipped UI.
// A subagent's own view opens under a "Subagent of <chat>" pill (subagents/SubagentGroup.tsx
// SubagentOfRow). A chat with no title yet still names something there: the chat's own fallback
// name, as the pane's header and its label use, never "Subagent of" with nothing after it. The page
// is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-subagent-of-untitled.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-subagent-of-untitled: skipping (run `bunx playwright install chromium`)");
    describe.skip("subagent of an untitled chat", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const UNTITLED = "0190a000-0000-7000-8000-0000000000c1";
  const TITLED = "0190a000-0000-7000-8000-0000000000c2";
  const START = Date.now() - 90_000;
  const update = (update: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update, ...(meta ? { _meta: { acpmux: meta } } : {}) },
  });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Review the branch with an agent" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned" },
        { subagents: [{ id: "a1", parent: null, name: "Reviewer", state: "completed" }] },
      ),
    ],
    [
      "in",
      "agent_message_chunk",
      update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "The review is in." } }),
    ],
    ["mux", "turn_result", { status: "completed" }],
  ];
  const events = (session: string) =>
    steps.map(([dir, kind, msg], index) => ({
      sessionId: session,
      seq: index + 1,
      at: START + (index + 1) * 1000,
      dir,
      kind,
      msg,
    }));
  const session = (sessionId: string) => ({
    sessionId,
    cwd: "/home/dev/uploader",
    ...(sessionId === TITLED ? { title: "Release review" } : {}),
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  });

  function answer(method: string, params: Record<string, any> = {}): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session(UNTITLED), session(TITLED)] };
      case "_acpmux/attach": {
        const id = params.sessionId === TITLED ? TITLED : UNTITLED;
        return { session: session(id), lastSeq: steps.length, events: events(id) };
      }
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: 0 };
      default:
        return null;
    }
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = (session: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${session}`;
  };
  /// Opens `session`'s chat, then its subagent's own view, and reads the pill's parent name.
  const parentShown = async (session: string) => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(session));
    await page.getByText("The review is in.").waitFor({ timeout: 25_000 });
    await page.locator("button.cv-subagents").click();
    await page.getByRole("button", { name: /Reviewer/ }).click();
    await page.locator(".cv-subagent-of").waitFor({ timeout: 5_000 });
    const parent = (await page.locator(".cv-subagent-of__parent").textContent())?.trim();
    await page.close();
    return parent;
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
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  test("the pill names a titled chat by its title", async () => {
    expect(await parentShown(TITLED)).toBe("Release review");
  });

  test("an untitled chat's pill names the chat's fallback, not nothing", async () => {
    expect(await parentShown(UNTITLED)).toBe("Agent Chat");
  });
});
