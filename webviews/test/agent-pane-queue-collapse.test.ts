// l10n-allow-file: test fixture prompts, not shipped UI.
// A long queue above the composer, as Leo asked on 2026-10-14 (PR #20391): the row's actions sit
// on the row itself, with no fade drawn over its text, and many queued prompts fold behind one
// "N more queued" row that opens in place to the whole list and closes back. The page is the
// pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a
// WebSocket to a stand-in acpmux daemon whose one chat has a turn running and six prompts queued
// behind it, and which answers `_acpmux/queue_edit` as acpmux does (`queue_order`, `dequeued`).
//
// - A queued row's actions have no gradient (or any image or blur) behind them and never cover
//   its text.
// - Six queued prompts show the next two and "4 more queued"; it opens to all six in order, keeps
//   their numbers, and closes back; ↑ from the prompt reaches it, Return and Space toggle it.
// - Sending the next prompt keeps the folded count right; a move into the folded part opens it.
//
// Real WebKit (the engine cmux NEXT draws with) from Playwright; CI fails the file when it cannot
// launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { webkit, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-queue-collapse.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await webkit.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-queue-collapse: skipping (run `bunx playwright install webkit`)");
    describe.skip("queue collapse", () => test("webkit", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "queue-collapse-session";
  const turn = { turnId: "turn-1", promptId: "p-turn", startedAt: Date.now(), prompt: "Refactor the parser" };
  const PROMPTS = ["one", "two", "three", "four", "five", "six"];
  let queue: { promptId: string; prompt: string }[] = [];
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Refactor the parser",
    harness: "codex",
    status: "running",
    steering: true,
    queuePaused: false,
    queued: queue.length,
    queue,
    turn,
    updatedAt: Date.now(),
  });
  const opening = [
    {
      sessionId: SESSION,
      seq: 1,
      at: Date.now(),
      dir: "mux",
      kind: "user_message",
      msg: { text: turn.prompt, promptId: "p-turn", turnId: "turn-1" },
    },
  ];
  let seq = opening.length;
  const edits: Record<string, any>[] = [];

  type Socket = { send(data: string): void };
  const event = (ws: Socket, kind: string, msg: Record<string, unknown>) =>
    ws.send(
      JSON.stringify({
        jsonrpc: "2.0",
        method: "_acpmux/event",
        params: { sessionId: SESSION, seq: ++seq, at: Date.now(), dir: "mux", kind, msg },
      }),
    );

  /// acpmux's answer, and the records every client hears.
  function answer(ws: Socket, method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [] } } };
      case "_acpmux/watch":
        return { sessions: [summary()] };
      case "_acpmux/attach":
        return { session: summary(), lastSeq: seq, events: opening };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: seq };
      case "_acpmux/queue_edit": {
        edits.push({ ...params });
        delete edits.at(-1)!.sessionId;
        const entry = queue.find((q) => q.promptId === params.promptId);
        if (!entry) return { ok: false };
        if (params.op === "move") {
          queue = queue.filter((q) => q !== entry);
          queue.splice(params.index, 0, entry);
          event(ws, "queue_order", { promptId: entry.promptId, order: queue.map((q) => q.promptId) });
        } else if (params.op === "send_now") {
          queue = queue.filter((q) => q !== entry);
          event(ws, "dequeued", { promptId: entry.promptId });
          event(ws, "user_message", { text: entry.prompt, promptId: entry.promptId, turnId: "turn-1", steer: true });
        }
        return { ok: true, ...(params.op === "send_now" ? { sent: "steer" } : {}) };
      }
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
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          const result = answer(ws, message.method, message.params ?? {});
          if (message.id !== undefined) ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
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
    browser = await webkit.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(prompts: string[]): Promise<Page> {
    queue = prompts.map((prompt, i) => ({ promptId: `q-${i + 1}`, prompt }));
    edits.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.locator('.acpmux-queued[data-prompt-id="q-1"]').waitFor();
    return page;
  }

  /// What the queue shows: each row's number and text, then its fold control's label and state.
  const shown = (page: Page) =>
    page.evaluate(() => {
      const list = document.querySelector(".acpmux-composer-queue");
      const rows = [...(list?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? [])].map(
        (row) =>
          `${row.querySelector(".acpmux-queued-mark")?.textContent ?? ""} ${row.querySelector(".acpmux-queued-text")?.textContent ?? ""}`,
      );
      const fold = list?.querySelector<HTMLButtonElement>("button[aria-expanded].acpmux-queue-fold");
      return { rows, fold: fold ? `${fold.textContent} (${fold.getAttribute("aria-expanded")})` : null };
    });
  const focused = (page: Page) =>
    page.evaluate(() => {
      const active = document.activeElement as HTMLElement | null;
      return active?.dataset.promptId ?? (active?.classList.contains("acpmux-queue-fold") ? "fold" : null);
    });

  describe("a long queue", () => {
    test("a queued row's actions have no fade behind them and never cover its text", async () => {
      const page = await openChat(["a prompt long enough to reach the row's actions ".repeat(6)]);
      const row = page.locator('.acpmux-queued[data-prompt-id="q-1"]');
      await row.hover();
      const layout = await row.evaluate((li) => {
        const actions = li.querySelector<HTMLElement>(".acpmux-queued-actions")!;
        const text = li.querySelector<HTMLElement>(".acpmux-queued-clamp")!.getBoundingClientRect();
        const box = actions.getBoundingClientRect();
        const style = getComputedStyle(actions);
        const blur = (style as CSSStyleDeclaration & { webkitBackdropFilter?: string }).webkitBackdropFilter;
        return {
          image: style.backgroundImage,
          rowImage: getComputedStyle(li).backgroundImage,
          blur: [style.backdropFilter, blur].filter((value) => value && value !== "none"),
          overlap: box.left < text.right && text.left < box.right && box.top < text.bottom && text.top < box.bottom,
        };
      });
      expect(layout).toEqual({ image: "none", rowImage: "none", blur: [], overlap: false });
      await page.close();
    });

    test("six queued prompts fold behind '4 more queued', which opens and closes in place", async () => {
      const page = await openChat(PROMPTS);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      expect(await shown(page)).toEqual({ rows: ["1 one", "2 two"], fold: "4 more queued (false)" });

      // ↑ from the empty prompt reaches the fold first; Return opens it, and it keeps focus.
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("fold");
      await page.keyboard.press("Enter");
      expect(await shown(page)).toEqual({
        rows: ["1 one", "2 two", "3 three", "4 four", "5 five", "6 six"],
        fold: "Show less (true)",
      });
      expect(await focused(page)).toBe("fold");
      // Space closes it; ↑ goes on to the last row it shows, ↓ comes back, and ↓ again to the prompt.
      await page.keyboard.press("Space");
      expect(await shown(page)).toEqual({ rows: ["1 one", "2 two"], fold: "4 more queued (false)" });
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-2");
      await page.keyboard.press("ArrowDown");
      expect(await focused(page)).toBe("fold");
      await page.keyboard.press("ArrowDown");
      expect(await page.evaluate(() => document.activeElement?.classList.contains("acpmux-composer-prompt"))).toBe(true);

      // A click opens it too.
      await page.locator(".acpmux-queue-fold").click();
      expect((await shown(page)).rows).toHaveLength(6);
      await page.locator(".acpmux-queue-fold").click();
      expect((await shown(page)).fold).toBe("4 more queued (false)");
      await page.close();
    });

    test("sending the next prompt keeps the fold's count right; a move into the fold opens it", async () => {
      const page = await openChat(PROMPTS);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      const row = page.locator('.acpmux-queued[data-prompt-id="q-1"]');
      await row.hover();
      await row.getByRole("button", { name: "Send now" }).click();
      await page.waitForFunction(() => !document.querySelector('.acpmux-queued[data-prompt-id="q-1"]'));
      expect(await shown(page)).toEqual({ rows: ["1 two", "2 three"], fold: "3 more queued (false)" });

      // ⌥↓ on the last row shown moves it into the folded part: the list opens, and it keeps focus.
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-3");
      await page.keyboard.press("Alt+ArrowDown");
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-queued .acpmux-queued-text")[2]?.textContent === "three",
      );
      await page.waitForFunction(() => (document.activeElement as HTMLElement | null)?.dataset.promptId === "q-3");
      expect({ edits, ...(await shown(page)) }).toEqual({
        edits: [
          { op: "send_now", promptId: "q-1" },
          { op: "move", promptId: "q-3", index: 2 },
        ],
        rows: ["1 two", "2 four", "3 three", "4 five", "5 six"],
        fold: "Show less (true)",
      });
      await page.close();
    });
  });
});
