// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// A finished turn's Edited files card and its diff (cx-ncc.82, Claude parity). The card's header
// always shows the turn's +/- totals beside one View changes; the diff opens as a column on the right,
// beside the transcript, which stays visible and reflows narrower, on a wide pane and a narrow one
// alike (Leo, 2026-10-31: "why does it still not open to the right"; it used to cover the
// transcript below 1160px). The page is the pane's dev entry with its browser host, talking
// JSON-RPC to a stand-in acpmux daemon.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-edited-side.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-edited-side: skipping (run `bunx playwright install chromium`)");
    describe.skip("edited side", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c1";
  const START = Date.UTC(2026, 9, 11, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const edit = (id: string, path: string, oldText: string, newText: string): Step[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: `Edit ${path}`,
        kind: "edit",
        status: "in_progress",
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "diff", path, oldText, newText }],
      }),
    ],
  ];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Add retry to the uploader" }],
    ["mux", "turn_started", {}],
    ...edit("e1", "/home/dev/uploader/src/upload.ts", "a\nb\n", "a\nretry\nb\nbackoff\n"),
    ...edit("e2", "/home/dev/uploader/README.md", "x\ny\n", "x\n"),
    ["in", "agent_message_chunk", say("Retry added to the uploader.")],
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
    // again if it stalls, so the test times only the card.
    for (let attempt = 1; ; attempt++) {
      const warm = await browser.newPage();
      try {
        await warm.goto(url(CHAT));
        await warm.getByText("Retry added to the uploader.").waitFor({ timeout: 25_000 });
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

  const box = (page: import("playwright").Page, selector: string) =>
    page.evaluate((query) => {
      const node = document.querySelector(query);
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { left: rect.left, right: rect.right, visible: getComputedStyle(node).visibility !== "hidden" };
    }, selector);

  test("the card's header shows the turn's totals beside one View changes", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    const card = page.locator(".acpmux-edited");
    expect(await card.locator(".acpmux-edited-head").getByRole("button", { name: "View changes" }).count()).toBe(1);
    expect(await card.locator(".acpmux-edited-sub .acpmux-diff-add").textContent()).toBe("+2");
    expect(await card.locator(".acpmux-edited-sub .acpmux-diff-del").textContent()).toBe("-1");
    await page.close();
  });

  test("on a wide pane the diff opens beside the transcript, which stays visible", async () => {
    const page = await browser!.newPage({ viewport: { width: 1500, height: 800 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    await page.locator(".acpmux-edited-head .acpmux-review-changes").click();
    await page.locator(".acpmux-diff-panel").waitFor();
    const scroll = await box(page, ".acpmux-scroll");
    const panel = await box(page, ".acpmux-diff-panel");
    expect(scroll?.visible).toBe(true);
    expect(panel!.left).toBeGreaterThan(400);
    expect(scroll!.right).toBeLessThanOrEqual(panel!.left + 1);
    await expect(page.getByText("Retry added to the uploader.").isVisible()).resolves.toBe(true);
    await page.close();
  });

  test("on a narrow pane the diff still opens on the right, never over the transcript", async () => {
    const page = await browser!.newPage({ viewport: { width: 800, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Retry added to the uploader.").waitFor();
    await page.locator(".acpmux-edited-head .acpmux-review-changes").click();
    await page.locator(".acpmux-diff-panel").waitFor();
    const scroll = await box(page, ".acpmux-scroll");
    const panel = await box(page, ".acpmux-diff-panel");
    expect(scroll?.visible).toBe(true);
    // The chat keeps at least 320px on the left; the diff takes the rest on the right.
    expect(panel!.left).toBeGreaterThanOrEqual(320);
    expect(scroll!.right).toBeLessThanOrEqual(panel!.left + 1);
    await page.close();
  });
});
