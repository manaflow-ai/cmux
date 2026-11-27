// Managing queued prompts from the keyboard, in the real agent pane (cx-xtg0.4). The page is the
// pane's dev entry (vite.config.acpmux-pane.mjs) with its browser host, talking JSON-RPC over a
// WebSocket to a stand-in acpmux daemon whose one chat has a turn running and three prompts queued
// behind it, and which answers `_acpmux/queue_edit` and `_acpmux/queue_remove` as acpmux does: a
// change is a record every client hears (`queue_order`, `queue_updated`, `dequeued`).
//
// - ↑ on the empty prompt reaches the last queued prompt; ⌥↑ moves it up, and it keeps focus.
// - Return edits a queued prompt in its row; it keeps its place. So does the ⋯ menu's Edit message.
// - The X on a steer the agent has not read takes it back into the composer; what is sent then is
//   the edited text. One acpmux refuses says Read after this step and stays for the next click.
// - ⌘Return on a queued prompt does nothing (it means "not now"); Delete removes one.
// - A queue a failed turn paused says so, and Resume runs it again.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-queue.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-queue: skipping (run `bunx playwright install chromium`)");
    describe.skip("queue management", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const SESSION = "queue-session";
  const turn = { turnId: "turn-1", promptId: "p-turn", startedAt: Date.now(), prompt: "Refactor the parser" };
  let queue: { promptId: string; prompt: string }[] = [];
  let paused = false;
  /// A Claude Code chat (acpmux's `backgroundsWork`) takes a waiting steer back (`withdraw`).
  let claude = false;
  /// The steer the agent has not read yet, which `withdraw` takes back.
  let waitingSteer: string | undefined;
  /// How many of the next withdraws acpmux refuses while the steer still waits (it registers a steer
  /// as withdrawable only once its images are prepared, steer_end.rs).
  let refuseWithdraws = 0;
  /// The prompts the page sent (`session/prompt`), as text, and who waits for the next.
  const sent: string[] = [];
  let onSent: (() => void) | undefined;
  const summary = () => ({
    sessionId: SESSION,
    cwd: "/home/dev/api",
    title: "Refactor the parser",
    harness: "codex",
    status: "running",
    steering: true,
    queuePaused: paused,
    ...(claude ? { backgroundsWork: true } : {}),
    queued: queue.length,
    queue,
    turn,
    updatedAt: Date.now(),
  });
  const opening: { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: object }[] = [
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
      case "_acpmux/queue_remove": {
        edits.push({ op: "remove", promptId: params.promptId });
        queue = queue.filter((q) => q.promptId !== params.promptId);
        event(ws, "queue_removed", { promptId: params.promptId });
        return { removed: true };
      }
      case "session/prompt": {
        sent.push(
          (params.prompt as { type: string; text?: string }[])
            .filter((block) => block.type === "text")
            .map((block) => block.text)
            .join(""),
        );
        onSent?.();
        return { stopReason: "end_turn" };
      }
      case "_acpmux/queue_edit": {
        edits.push({ ...params });
        delete edits.at(-1)!.sessionId;
        if (params.op === "withdraw") {
          if (refuseWithdraws > 0) {
            refuseWithdraws--;
            return { ok: false };
          }
          const took = params.promptId === waitingSteer;
          if (took) event(ws, "steer_withdrawn", { promptId: waitingSteer, turnId: "turn-1" });
          waitingSteer = undefined;
          return { ok: took };
        }
        const entry = queue.find((q) => q.promptId === params.promptId);
        if (!entry) return { ok: false };
        if (params.op === "move") {
          queue = queue.filter((q) => q !== entry);
          queue.splice(params.index, 0, entry);
          event(ws, "queue_order", { promptId: entry.promptId, order: queue.map((q) => q.promptId) });
        } else if (params.op === "update") {
          entry.prompt = params.text;
          event(ws, "queue_updated", { promptId: entry.promptId, text: params.text });
        } else if (params.op === "resume") {
          paused = false;
          event(ws, "queue_resumed", { queued: queue.length });
          ws.send(
            JSON.stringify({
              jsonrpc: "2.0",
              method: "_acpmux/session_changed",
              params: { sessionId: SESSION, session: summary(), kind: "queue", recordKind: "queue_resumed", seq },
            }),
          );
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
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  async function openChat(first = "first", pausedQueue = false, steer?: string, refuses = 0): Promise<Page> {
    paused = pausedQueue;
    claude = steer !== undefined;
    waitingSteer = steer === undefined ? undefined : "p-steer";
    refuseWithdraws = refuses;
    sent.length = 0;
    opening.length = 1;
    if (steer !== undefined)
      opening.push({
        sessionId: SESSION,
        seq: ++seq,
        at: Date.now(),
        dir: "mux",
        kind: "user_message",
        msg: { text: steer, promptId: "p-steer", turnId: "turn-1", steer: true },
      });
    queue = [
      { promptId: "q-1", prompt: first },
      { promptId: "q-2", prompt: "second" },
      { promptId: "q-3", prompt: "third" },
    ];
    edits.length = 0;
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.locator(".acpmux-queued", { hasText: "third" }).waitFor();
    return page;
  }

  const rows = (page: Page) => page.locator(".acpmux-queued .acpmux-queued-text").allInnerTexts();
  const focused = (page: Page) =>
    page.evaluate(() => (document.activeElement as HTMLElement | null)?.dataset.promptId ?? null);

  describe("queued prompts from the keyboard", () => {
    test("a queue a failed turn paused says so, and Resume runs it again", async () => {
      const page = await openChat("first", true);
      const note = page.locator(".acpmux-queue-paused", { hasText: "Paused after an error" });
      await note.waitFor({ timeout: 10_000 });
      await note.getByRole("button", { name: "Resume" }).click();
      await note.waitFor({ state: "detached" });
      expect({ edits, rows: await rows(page) }).toEqual({
        edits: [{ op: "resume", promptId: "q-1" }],
        rows: ["first", "second", "third"],
      });
      await page.close();
    });

    test("↑ on the empty prompt reaches the last queued prompt; ⌥↑ moves it up", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-3");
      await page.keyboard.press("Alt+ArrowUp");
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-queued .acpmux-queued-text")[1]?.textContent === "third",
      );
      await page.waitForFunction(() => (document.activeElement as HTMLElement | null)?.dataset.promptId === "q-3");
      expect({ edits, rows: await rows(page) }).toEqual({
        edits: [{ op: "move", promptId: "q-3", index: 1 }],
        rows: ["first", "third", "second"],
      });
      await page.close();
    });

    test("Return edits a queued prompt in its row, and it keeps its place", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-1");
      await page.keyboard.press("Enter");
      const input = page.getByRole("textbox", { name: "Edit queued prompt" });
      await input.waitFor();
      await input.fill("first, edited");
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-queued-text", { hasText: "first, edited" }).waitFor();
      expect({ edits, rows: await rows(page) }).toEqual({
        edits: [{ op: "update", promptId: "q-1", text: "first, edited" }],
        rows: ["first, edited", "second", "third"],
      });
      await page.close();
    });

    // Leo, 2026-10-29: "Plus this fucking edit message thing. It doesn't even fucking work." The ⋯
    // menu's Edit message opens the prompt in its row, and saving it updates the prompt acpmux sends.
    test("the ⋯ menu's Edit message edits a queued prompt in its row, and saving updates the prompt acpmux will send", async () => {
      const page = await openChat();
      const row = page.locator('.acpmux-queued[data-prompt-id="q-1"]');
      await row.hover();
      await row.locator('[data-menu="queued-more"]').click();
      await page.getByRole("menuitem", { name: /^Edit message/ }).click();
      const input = page.getByRole("textbox", { name: "Edit queued prompt" });
      await input.waitFor();
      // The menu closing leaves the edit open and focused: typing goes into it.
      expect(await input.evaluate((field) => field === document.activeElement)).toBe(true);
      await input.fill("first, edited");
      await page.keyboard.press("Enter");
      await page.locator(".acpmux-queued-text", { hasText: "first, edited" }).waitFor();
      expect({ edits, rows: await rows(page) }).toEqual({
        edits: [{ op: "update", promptId: "q-1", text: "first, edited" }],
        rows: ["first, edited", "second", "third"],
      });
      await page.close();
    });

    // The X (its tooltip Edit message) on a steer the agent has not read: acpmux takes it back, its
    // text comes back into the composer, and the edited text is what is sent.
    test("the X on a waiting steer puts its text in the composer, and the edited text is what is sent", async () => {
      const page = await openChat("first", false, "Use the cache dir");
      const bubble = page.locator(".cv-user__bubble", { hasText: "Use the cache dir" });
      await bubble.waitFor();
      await bubble.hover();
      await page.getByRole("button", { name: "Edit message" }).click();
      await bubble.waitFor({ state: "detached" });
      const prompt = page.locator(".acpmux-composer-prompt");
      await prompt.filter({ hasText: "Use the cache dir" }).waitFor();
      expect(edits).toEqual([{ op: "withdraw", promptId: "p-steer" }]);
      await prompt.click();
      await page.keyboard.press("End");
      await page.keyboard.type(" for the next run");
      const delivered = new Promise<void>((resolve) => (onSent = resolve));
      await page.keyboard.press("Enter");
      await delivered;
      expect(sent).toEqual(["Use the cache dir for the next run"]);
      await page.close();
    });

    // Review of #27672: acpmux refuses a withdraw for a moment right after a steer is sent. The row
    // says Read after this step, the X stays (the pointer leaving draws nothing again), and the next
    // click takes the steer back into the composer.
    test("an X acpmux refuses once says Read after this step and stays; the next click takes the steer back", async () => {
      const page = await openChat("first", false, "Use the cache dir", 1);
      const steer = page.locator(".cv-user", { hasText: "Use the cache dir" });
      const x = steer.getByRole("button", { name: "Edit message" });
      await steer.locator(".cv-user__bubble").hover();
      await x.click();
      await steer.locator(".cv-user__kept", { hasText: "Read after this step" }).waitFor();
      await page.mouse.move(2, 2);
      expect({ notes: await steer.locator(".cv-user__kept").count(), xs: await x.count() }).toEqual({
        notes: 1,
        xs: 1,
      });
      expect(await x.isEnabled()).toBe(true);
      await x.click();
      await steer.waitFor({ state: "detached" });
      await page.locator(".acpmux-composer-prompt").filter({ hasText: "Use the cache dir" }).waitFor();
      expect(edits).toEqual([
        { op: "withdraw", promptId: "p-steer" },
        { op: "withdraw", promptId: "p-steer" },
      ]);
      await page.close();
    });

    test("⌥↓ keeps focus on the prompt it moved", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowUp");
      await page.keyboard.press("Alt+ArrowDown");
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-queued .acpmux-queued-text")[1]?.textContent === "first",
      );
      await page.waitForFunction(() => (document.activeElement as HTMLElement | null)?.dataset.promptId === "q-1");
      await page.keyboard.press("Alt+ArrowDown");
      await page.waitForFunction(
        () => document.querySelectorAll(".acpmux-queued .acpmux-queued-text")[2]?.textContent === "first",
      );
      expect({ edits, rows: await rows(page), focused: await focused(page) }).toEqual({
        edits: [
          { op: "move", promptId: "q-1", index: 1 },
          { op: "move", promptId: "q-1", index: 2 },
        ],
        rows: ["second", "third", "first"],
        focused: "q-1",
      });
      await page.close();
    });

    test("an edit opened and saved unchanged keeps a prompt's lines and sends nothing", async () => {
      const page = await openChat("line one\nline two");
      await page.locator(".acpmux-composer-prompt").click();
      for (let i = 0; i < 3; i++) await page.keyboard.press("ArrowUp");
      await page.keyboard.press("Enter");
      const input = page.getByRole("textbox", { name: "Edit queued prompt" });
      await input.waitFor();
      expect(await input.inputValue()).toBe("line one\nline two");
      await page.keyboard.press("Enter");
      await input.waitFor({ state: "detached" });
      // The save sent nothing: the next change, a Delete, is the first acpmux hears.
      await page.keyboard.press("Delete");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 2);
      expect(edits).toEqual([{ op: "remove", promptId: "q-1" }]);
      await page.close();
    });

    test("⌘Return on a queued prompt sends nothing and keeps it focused; Delete removes it", async () => {
      const page = await openChat();
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-2");
      await page.keyboard.press("Meta+Enter");
      expect(await focused(page)).toBe("q-2");
      // ⌘Return sent nothing: the Delete after it is the first change acpmux hears.
      await page.keyboard.press("Delete");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 2);
      expect({ edits, rows: await rows(page) }).toEqual({
        edits: [{ op: "remove", promptId: "q-2" }],
        rows: ["first", "third"],
      });
      await page.close();
    });
  });
});
