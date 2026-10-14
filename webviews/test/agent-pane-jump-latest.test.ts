// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// Jump to latest (Leo 2026-10-13, cmux NEXT), as Codex and Claude desktop do it: one short, steady
// glide down to the end, with the button gone for good once clicked; it lands on the very end
// even while the reply grows under it, and the view keeps following. Following, tool calls and
// commands glide in like text (never a snap), and a command the reader opens holds still under
// the pointer; scrolled up, nothing moves.
//
// Before: the smooth scroll stopped the view following on its first frame, so the button came
// back mid-scroll and the end was reached by a hard snap 600 ms later, which any wheel event
// (a trackpad's momentum) cancelled, leaving the view short of the end. A row taller than the view
// snapped, a new row rose on its own while the thread glid, and opening a command while following
// pulled it up by its output.
//
// Each frame is read after it paints (a task queued from requestAnimationFrame).
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux.
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-jump-latest.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-jump-latest: skipping (run `bunx playwright install chromium`)");
    describe.skip("jump to latest", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const START = Date.UTC(2026, 9, 13, 9, 0, 0);
  const paragraph = (index: number) =>
    `Paragraph ${index}. A client that fails waits a little longer before each retry, and adds a ` +
    "random jitter so a crowd of clients does not retry in step.\n\n";
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  const OUTPUT = Array.from({ length: 14 }, (_, index) => `build/step-${index}.o`).join("\n");

  type Socket = { send(data: string): void };
  type Chat = { id: string; seq: number; events: Record<string, unknown>[]; ws?: Socket };
  const chats = new Map<string, Chat>();
  const summary = (chat: Chat) => ({
    sessionId: chat.id,
    cwd: "/home/dev/sun",
    title: "Backoff",
    harness: "codex",
    family: "codex",
    status: "running",
    steering: true,
    turnCount: 1,
    updatedAt: START,
  });
  const record = (chat: Chat, dir: string, kind: string, msg: Record<string, unknown>) => {
    const event = { sessionId: chat.id, seq: ++chat.seq, at: START + chat.seq * 1000, dir, kind, msg };
    chat.events.push(event);
    return event;
  };
  /// A chat a turn is running in: a prompt, a command with output to open, and a long reply so far.
  function newChat(): Chat {
    const chat: Chat = {
      id: `0190a000-0000-7000-8000-${String(chats.size + 1).padStart(12, "0")}`,
      seq: 0,
      events: [],
    };
    chats.set(chat.id, chat);
    record(chat, "mux", "user_message", { text: "Why does the build retry?", promptId: "p-1" });
    record(chat, "mux", "turn_started", {});
    record(
      chat,
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "c1",
        title: "ls build",
        kind: "execute",
        status: "in_progress",
        rawInput: { command: "ls build" },
      }),
    );
    record(
      chat,
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: "c1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: OUTPUT } }],
      }),
    );
    for (let index = 1; index <= 24; index++) record(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
    return chat;
  }
  /// One more record, live to the page.
  const push = (chat: Chat, dir: string, kind: string, msg: Record<string, unknown>) =>
    chat.ws!.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: record(chat, dir, kind, msg) }));

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
          const chat = chats.get(String(message.params?.sessionId ?? "")) ?? [...chats.values()].at(-1)!;
          let result: unknown = null;
          if (message.method === "initialize")
            result = { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
          else if (message.method === "_acpmux/watch") result = { sessions: [summary(chat)] };
          else if (message.method === "_acpmux/attach") {
            chat.ws = ws;
            result = { session: summary(chat), lastSeq: chat.seq, events: chat.events };
          } else if (message.method === "_acpmux/events") result = { events: [], hasMore: false, lastSeq: chat.seq };
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
    browser = await chromium.launch({ headless: true });
    // A cold dev server's first load can stall in CI: load it here, again if it stalls.
    for (let attempt = 1; ; attempt++) {
      try {
        const page = await open(newChat(), 900);
        await page.close();
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

  async function open(chat: Chat, width: number, height = 700): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width, height } });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat.id}`);
    await page.getByText("Paragraph 24.", { exact: false }).waitFor({ timeout: 25_000 });
    // Rows place by their drawn heights a frame after they mount.
    await page.waitForTimeout(300);
    return page;
  }

  /// Scrolls to the transcript's start as a reader does, so its first rows mount.
  async function toStart(page: Page) {
    await page.locator(".acpmux-scroll").hover();
    for (let step = 0; step < 6; step++) await page.mouse.wheel(0, -4000);
    await page.waitForTimeout(300);
  }
  const button = (page: Page) => page.locator(".acpmux-jump-latest");
  /// Every painted frame until `stop`: the scroll offset, how far the view sits above the
  /// transcript's end by its spacer (transforms aside), whether the button shows, and, given
  /// `text`, the top of the paragraph that holds it.
  type Shot = { scrollTop: number; fromEnd: number; shown: boolean; top: number | null };
  const film = (page: Page, text?: string) =>
    page.evaluate((text) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const spacer = scroller.querySelector<HTMLElement>(".acpmux-spacer");
      const sample = () => {
        const paragraph = text
          ? [...scroller.querySelectorAll("p")].find((p) => p.textContent?.includes(text))
          : undefined;
        const end = spacer ? spacer.offsetHeight : scroller.scrollHeight;
        return {
          scrollTop: Math.round(scroller.scrollTop),
          fromEnd: Math.round(end - scroller.scrollTop - scroller.clientHeight),
          shown: document.querySelector(".acpmux-jump-latest")?.hasAttribute("data-shown") ?? false,
          top: paragraph ? Math.round(paragraph.getBoundingClientRect().top) : null,
        };
      };
      const frames: unknown[] = [];
      (window as any).__shots = frames;
      const tick = () => {
        if ((window as any).__shots !== frames) return;
        setTimeout(() => frames.push(sample()), 0);
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
    }, text);
  const cut = async (page: Page, settle = 250): Promise<Shot[]> => {
    await page.waitForTimeout(settle);
    return page.evaluate(() => {
      const frames = (window as any).__shots as unknown[];
      (window as any).__shots = undefined;
      return frames as never;
    });
  };
  /// Scrolled up from the end, with the button showing.
  async function scrolledUp(page: Page) {
    await toStart(page);
    await expect(button(page).getAttribute("data-shown")).resolves.toBe("");
  }

  test("a jump is one steady glide down, and the button stays gone", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await scrolledUp(page);
    const viewport = await page.locator(".acpmux-scroll").evaluate((node) => node.clientHeight);
    await film(page);
    await button(page).click();
    const shots = await cut(page, 900);
    const moves = shots.flatMap((shot, index) => (index > 0 ? [shot.scrollTop - shots[index - 1]!.scrollTop] : []));
    const moving = moves.filter((move) => Math.abs(move) > 0.5);
    // Down only, never back up.
    expect(moves.filter((move) => move < -1)).toEqual([]);
    // A glide over several frames, not a snap; past its first frame no step is a big part of the view.
    expect(moving.length).toBeGreaterThanOrEqual(4);
    expect(Math.max(...moving.slice(1))).toBeLessThanOrEqual(viewport * 0.5);
    // Once it hid, it stays hidden.
    const hidden = shots.findIndex((shot) => !shot.shown);
    expect(hidden).toBeGreaterThanOrEqual(0);
    expect(shots.slice(hidden).filter((shot) => shot.shown).length).toBe(0);
    expect(shots.at(-1)!.fromEnd).toBeLessThanOrEqual(1);
    await page.close();
  });

  test("it lands on the very end while the reply grows, through a wheel's momentum, and keeps following", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await scrolledUp(page);
    await button(page).click();
    // A trackpad's momentum still arrives after the click; the reply keeps streaming.
    await page.mouse.wheel(0, 120);
    for (let index = 25; index <= 32; index++) {
      push(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
      await page.waitForTimeout(60);
    }
    await page.waitForTimeout(700);
    await film(page);
    const landed = await cut(page, 100);
    expect(landed.at(-1)!.fromEnd).toBeLessThanOrEqual(1);
    expect(landed.at(-1)!.shown).toBe(false);
    for (let index = 33; index <= 36; index++) {
      push(chat, "in", "agent_message_chunk", chunk(paragraph(index)));
      await page.waitForTimeout(60);
    }
    await page.waitForTimeout(500);
    await film(page);
    const following = await cut(page, 100);
    expect(following.at(-1)!.fromEnd).toBeLessThanOrEqual(1);
    await page.getByText("Paragraph 36.", { exact: false }).waitFor();
    await page.close();
  });

  /// A command the agent runs, live to the page; `done` finishes it with OUTPUT.
  const command = (chat: Chat, id: string, line: string, done: boolean) => {
    push(
      chat,
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: line,
        kind: "execute",
        status: "in_progress",
        rawInput: { command: line },
      }),
    );
    if (done)
      push(
        chat,
        "in",
        "tool_call_update",
        update({
          sessionUpdate: "tool_call_update",
          toolCallId: id,
          status: "completed",
          content: [{ type: "content", content: { type: "text", text: OUTPUT } }],
        }),
      );
  };
  /// Each frame's move of the watched paragraph on screen.
  const motion = (shots: Shot[]) =>
    shots
      .filter((shot) => shot.top !== null)
      .flatMap((shot, index, all) => (index > 0 ? [shot.top! - all[index - 1]!.top!] : []))
      .filter((move) => Math.abs(move) > 0.5);

  test("following, a tool call and a reply taller than the view glide in: never a snap, never back down", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await film(page, "Paragraph 24.");
    await page.waitForTimeout(100);
    command(chat, "t1", "npm test", true);
    await page.waitForTimeout(300);
    // The reply after it arrives at once, taller than the view.
    push(
      chat,
      "in",
      "agent_message_chunk",
      chunk(Array.from({ length: 9 }, (_, index) => paragraph(25 + index)).join("")),
    );
    await page.getByText("Paragraph 33.", { exact: false }).waitFor();
    const moves = motion(await cut(page, 400));
    expect(moves.reduce((sum, move) => sum + move, 0)).toBeLessThan(0);
    expect(moves.filter((move) => move > 1)).toEqual([]);
    // Spread over frames, not a jump of a frame or two.
    expect(moves.length).toBeGreaterThanOrEqual(5);
    await page.close();
  });

  test("following, opening a command at the end keeps it under the pointer", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    command(chat, "c2", "npm test", true);
    const toggle = page.locator("button[aria-expanded]", { hasText: "npm test" }).first();
    await toggle.waitFor();
    await page.waitForTimeout(400);
    await film(page);
    const top = () => toggle.evaluate((node) => Math.round(node.getBoundingClientRect().top));
    // A plain click where the toggle is: a locator click may scroll it first, which is not the app.
    const box = (await toggle.boundingBox())!;
    const before = await top();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    const tops: number[] = [];
    for (let frame = 0; frame < 12; frame++) {
      tops.push(await top());
      await page.waitForTimeout(25);
    }
    await page.getByText("build/step-13.o").last().waitFor();
    tops.push(await top());
    expect(tops.filter((value) => Math.abs(value - before) > 1)).toEqual([]);
    // The output it opened runs past the end: the button offers the way back.
    expect((await cut(page, 100)).at(-1)!.shown).toBe(true);
    await page.close();
  });

  test("scrolled up, nothing moves while tool calls arrive", async () => {
    const chat = newChat();
    const page = await open(chat, 900);
    await page.locator(".acpmux-scroll").hover();
    await page.mouse.wheel(0, -900);
    await page.waitForTimeout(300);
    await film(page, "Paragraph 12.");
    for (const [index, line] of ["npm test", "npm run lint"].entries()) {
      command(chat, `t${index}`, line, index === 0);
      await page.waitForTimeout(200);
    }
    const tops = (await cut(page, 300)).map((shot) => shot.top);
    expect(tops.length).toBeGreaterThan(5);
    expect(new Set(tops)).toEqual(new Set([tops[0]!]));
    await page.close();
  });
});
