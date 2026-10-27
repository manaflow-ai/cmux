// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The chat's pull requests above the composer (cx-ncc.81, Claude parity): each PR a `gh pr create`
// in the chat opened shows as a bar with its number, repository, title and state; a later
// `gh pr merge` takes its bar away (it lives in the right panel's Changes card). The newest two
// show, the rest behind Show more, and a bar's
// dismiss hides it for this chat, also after a reload. The page is the pane's dev entry with its
// browser host, talking JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-pr-dock.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-pr-dock: skipping (run `bunx playwright install chromium`)");
    describe.skip("pr dock", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000b1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  /// A shell call that ran `command` and printed `output`.
  const shell = (id: string, command: string, output: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: output } }],
        rawOutput: { exit_code: 0 },
      }),
    ],
  ];
  const create = (id: string, title: string, number: number) =>
    shell(id, `gh pr create --title "${title}" --body x`, `https://github.com/acme/uploader/pull/${number}\n`);
  const steps: Step[] = [
    ["mux", "user_message", { text: "Open the four PRs, then merge the first" }],
    ["mux", "turn_started", {}],
    ...create("t1", "Add retry to the uploader", 41),
    ...create("t2", "Cover retry with a test", 42),
    ...create("t3", "Document retry", 43),
    ...create("t4", "Log each retry", 44),
    ...shell("t5", "gh pr merge 41 --squash", "Merged"),
    ["in", "agent_message_chunk", say("Four PRs open, the first merged.")],
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
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/uploader",
    title: "Uploader retry",
    harness: "claude",
    family: "claude",
    status: "idle",
    turnCount: 1,
    updatedAt: START,
  };

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
    // again if it stalls, so the test times only the bars.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Four PRs open, the first merged.").waitFor({ timeout: 25_000 });
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

  test("PRs share the message footer and remain available after reload", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    try {
      await page.goto(url(CHAT));
      await page.getByText("Four PRs open, the first merged.").waitFor();
      const dock = page.locator(".cv-turn-actions .acpmux-pr-dock");
      await dock.waitFor();
      const links = dock.locator(".acpmux-pr-dock__bar");
      expect(await links.count()).toBe(2);
      expect(await links.first().innerText()).toContain("#44");
      expect(await links.first().getAttribute("href")).toBe("https://github.com/acme/uploader/pull/44");
      expect(await dock.locator(".acpmux-pr-dock__dismiss").count()).toBe(0);
      await dock.locator(".acpmux-pr-dock__more").click();
      const popup = page.locator(".acpmux-pr-dock__popover");
      await popup.waitFor();
      expect(await popup.locator(".acpmux-pr-dock__bar").count()).toBe(2);
      expect(await popup.innerText()).toContain("#41");
      await page.mouse.click(10, 100);
      await popup.waitFor({ state: "detached" });
      await page.reload();
      await dock.waitFor();
      expect(await links.count()).toBe(2);
    } finally {
      await page.close();
    }
  });
});
