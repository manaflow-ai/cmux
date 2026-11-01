// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// The edits card's whole header is its toggle (Leo, 2026-10-31: "this thing i can't click the whole
// thing to expand/collapse only on the middle strip it's weird and bad"). A one-file card's header
// ("± Edited MEMORY.md +1 -0") opens and closes its diff from a click anywhere on it: the left
// padding, the icon, the right end past the chevron, and the top and bottom insets, not only the
// title's strip. View changes, a control of its own in the header, still opens the changes view and
// leaves the diff as it was. The page is the pane's dev entry with its browser host, talking
// JSON-RPC to a stand-in acpmux daemon (as agent-pane-edited-calm.test.ts).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-edited-head-toggle-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-edited-head-toggle: skipping (run `bunx playwright install chromium`)");
    describe.skip("edited head toggle", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-0000000000c7";
  const START = Date.UTC(2026, 9, 31, 9, 0, 0);
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const say = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Step = [dir: string, kind: string, msg: Record<string, unknown>];
  const steps: Step[] = [
    ["mux", "user_message", { text: "Remember the rule" }],
    ["mux", "turn_started", {}],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "e1",
        title: "Edit /home/dev/notes/MEMORY.md",
        kind: "edit",
        status: "in_progress",
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "e1",
        status: "completed",
        content: [{ type: "diff", path: "/home/dev/notes/MEMORY.md", oldText: "a\n", newText: "a\nb\n" }],
      }),
    ],
    ["in", "agent_message_chunk", say("Notes updated.")],
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
    cwd: "/home/dev/notes",
    title: "Notes",
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
        await warm.getByText("Notes updated.").waitFor({ timeout: 25_000 });
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

  const HEAD = ".acpmux-edited-head";
  const TOGGLE = ".acpmux-edited-head .acpmux-edited-toggle";
  const expanded = (page: Page) => page.locator(TOGGLE).getAttribute("aria-expanded");
  /// The header's box and its parts', measured fresh before each click (the fold holds the header
  /// in place, but nothing here relies on it).
  const boxes = (page: Page) =>
    page.evaluate((head) => {
      const rect = (node: Element | null) => {
        if (!node) throw new Error("missing");
        const box = node.getBoundingClientRect();
        return { left: box.left, right: box.right, top: box.top, bottom: box.bottom };
      };
      const header = document.querySelector(head)!;
      return {
        head: rect(header),
        icon: rect(header.querySelector(".acpmux-edited-icon")),
        counts: rect(header.querySelector(".acpmux-diff-counts")),
        title: rect(header.querySelector(".acpmux-edited-title > div")),
        view: rect(header.querySelector(".acpmux-review-changes")),
      };
    }, HEAD);

  test("a click anywhere on the one-file card's header opens and closes its diff", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Notes updated.").waitFor();
    await page.locator(TOGGLE).waitFor();
    const start = await expanded(page);
    type Box = Awaited<ReturnType<typeof boxes>>;
    const middle = (box: Box["head"]) => (box.top + box.bottom) / 2;
    const points: [string, (box: Box) => { x: number; y: number }][] = [
      ["the left padding", ({ head }) => ({ x: head.left + 3, y: middle(head) })],
      ["the icon", ({ icon }) => ({ x: (icon.left + icon.right) / 2, y: (icon.top + icon.bottom) / 2 })],
      ["the counts", ({ counts }) => ({ x: (counts.left + counts.right) / 2, y: (counts.top + counts.bottom) / 2 })],
      // Between the title's words and View changes: the header's empty middle.
      [
        "the empty space after the title",
        ({ counts, view }) => ({ x: (counts.right + view.left) / 2, y: middle(view) }),
      ],
      ["the right end, past the chevron", ({ head }) => ({ x: head.right - 2, y: middle(head) })],
      ["the top inset", ({ head, title }) => ({ x: (title.left + title.right) / 2, y: head.top + 1.5 })],
      ["the bottom inset", ({ head, title }) => ({ x: (title.left + title.right) / 2, y: head.bottom - 1.5 })],
      ["the top-left corner", ({ head }) => ({ x: head.left + 2, y: head.top + 2 })],
    ];
    let open = start === "true";
    for (const [where, at] of points) {
      const point = at(await boxes(page));
      const hit = await page.evaluate(
        ({ x, y }) => document.elementFromPoint(x, y)?.closest(".acpmux-edited-head") !== null,
        point,
      );
      expect({ where, inHeader: hit }).toEqual({ where, inHeader: true });
      await page.mouse.click(point.x, point.y);
      open = !open;
      expect({ where, expanded: await expanded(page) }).toEqual({ where, expanded: String(open) });
    }
    // The diff really opens from the header: its file card shows under it.
    if (!open) {
      const { head } = await boxes(page);
      await page.mouse.click(head.left + 3, middle(head));
      open = true;
    }
    await page.locator(".acpmux-edited .cv-edit-diff").waitFor();
    // View changes keeps its own click: it opens the changes view and leaves the diff open.
    await page.locator(".acpmux-edited-head .acpmux-review-changes").click();
    expect(await expanded(page)).toBe("true");
    await page.close();
  });

  test("the header's hover covers the header, not while a button of its own is pointed at", async () => {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    await page.goto(url(CHAT));
    await page.getByText("Notes updated.").waitFor();
    await page.locator(TOGGLE).waitFor();
    const background = () => page.locator(HEAD).evaluate((node) => getComputedStyle(node).backgroundColor);
    const rest = await background();
    const { head, view } = await boxes(page);
    await page.mouse.move(head.left + 3, middle(head));
    expect(await background()).not.toBe(rest);
    await page.mouse.move((view.left + view.right) / 2, (view.top + view.bottom) / 2);
    expect(await background()).toBe(rest);
    expect(await page.locator(HEAD).evaluate((node) => getComputedStyle(node).cursor)).toBe("default");
    await page.close();
    function middle(box: { top: number; bottom: number }) {
      return (box.top + box.bottom) / 2;
    }
  });
});
