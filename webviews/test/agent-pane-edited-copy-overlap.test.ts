// l10n-allow-file: test fixture prompts, replies and file text, not shipped UI.
// No message action sits over the Edited files card's controls (cx-ncc.106): with the pointer on
// the card or focus on one of its controls, every other visible button (the row's floating Copy,
// the turn's Copy and Retry) stays clear of View changes, Undo and the card's chevron. The page is the pane's dev entry with its browser host, talking
// JSON-RPC to a stand-in acpmux daemon (as agent-pane-edited-calm.test.ts).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-edited-copy-overlap.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-edited-copy-overlap: skipping (run `bunx playwright install chromium`)");
    describe.skip("edited copy overlap", () => test("chromium", () => {}));
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
  const edit = (id: string, path: string, oldText: string | null, newText: string): Step[] => [
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
    ...edit("e1", "/home/dev/uploader/src/net/upload.ts", "a\nb\n", "a\nretry\nb\nbackoff\n"),
    ...edit("e2", "/home/dev/uploader/README.md", "x\ny\n", "x\n"),
    ...edit("e3", "/home/dev/uploader/src/net/backoff.ts", null, "export const backoff = 2;\n"),
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

  /// Waits for the page to come to rest: its finite animations and transitions have finished, then
  /// two frames have painted, so what is read next is laid out as drawn.
  const atRest = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document
          .getAnimations()
          .filter(
            (animation) =>
              animation.playState === "running" && Number.isFinite(animation.effect?.getComputedTiming().endTime),
          );
      for (let moving = finite(); moving.length > 0; moving = finite())
        await Promise.allSettled(moving.map((animation) => animation.finished));
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });

  /// Visible buttons outside the card whose box meets a control inside it.
  const overlaps = (page: import("playwright").Page) =>
    page.evaluate(() => {
      const card = document.querySelector(".acpmux-edited");
      if (!card) throw new Error("no .acpmux-edited");
      const shown = (node: Element) => {
        for (let at: Element | null = node; at; at = at.parentElement) {
          const style = getComputedStyle(at);
          if (style.visibility === "hidden" || style.display === "none" || Number(style.opacity) === 0) return false;
        }
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0;
      };
      const name = (node: Element) =>
        `${node.getAttribute("aria-label") ?? node.textContent?.trim() ?? ""} (${node.getAttribute("class") ?? ""})`;
      const inside = [...card.querySelectorAll("button")].filter(shown);
      const outside = [...document.querySelectorAll("button")].filter((node) => !card.contains(node) && shown(node));
      const hits: string[] = [];
      for (const a of outside) {
        const ra = a.getBoundingClientRect();
        for (const b of inside) {
          const rb = b.getBoundingClientRect();
          const x = Math.min(ra.right, rb.right) - Math.max(ra.left, rb.left);
          const y = Math.min(ra.bottom, rb.bottom) - Math.max(ra.top, rb.top);
          if (x > 0.5 && y > 0.5) hits.push(`${name(a)} over ${name(b)}`);
        }
      }
      return hits;
    });

  for (const width of [520, 900, 1180]) {
    test(`at ${width}px no other button sits over the card's controls while the card is hovered or focused`, async () => {
      const page = await browser!.newPage({ viewport: { width, height: 760 } });
      await page.goto(url(CHAT));
      await page.getByText("Retry added to the uploader.").waitFor();
      await page.locator(".acpmux-edited-file").first().waitFor();
      await installPaintedFrames(page);
      // Hovered, then with focus inside the card (a click or Tab onto one of its controls): the
      // row's floating Copy showed on :focus-within, at the row's top-right, over View changes.
      for (const target of [".acpmux-edited-head", ".acpmux-edited-file"]) {
        await page.locator(target).first().hover();
        await atRest(page);
        expect({ target, hits: await overlaps(page) }).toEqual({ target, hits: [] });
      }
      for (const control of await page.locator(".acpmux-edited button").all()) {
        await control.focus();
        await atRest(page);
        const target = await control.evaluate((node) => node.getAttribute("class") ?? node.textContent ?? "");
        expect({ target, hits: await overlaps(page) }).toEqual({ target, hits: [] });
      }
      await page.close();
    });
  }
});
