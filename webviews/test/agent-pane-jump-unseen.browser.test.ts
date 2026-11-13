// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The one jump control on the reader's seen cursor (jumpControl.ts, direct.ts `readCursor`, acpmux
// hub/seen.rs `read_through`), in Chromium, for a small chat and the god chat (bench/godFixture.ts).
// Leo, 2026-11-12: "it doesn't actually keep track of, like, when the things, you know? Because,
// like, when you restart the update, all of a sudden it's just, like, you know, it's there and it's
// noisy".
//
// The page is the pane's dev entry with its browser host, talking JSON-RPC to a stand-in acpmux that
// keeps one cursor, moved only by `_acpmux/seen`, forward only, and answers it with every attach:
// (a) a restart (the page reloads and attaches again) with nothing new: no arrow, nothing scrolls;
// (b) agent turns taller than the view arrive while the window has no focus: the cursor stays, the
//     up arrow shows, and after focus and input a press lands the first unseen row near the top;
// (c) a reconnect and a notice-only turn move no cursor and bring no arrow;
// (d) scrolling up past the unseen rows and back down while attending sees them: the arrow goes and
//     the cursor reaches the newest reply.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { godChat, LATEST_TEXT } from "../bench/godFixture";
import { newestPage } from "../bench/daemonPage";
import { installPaintedFrames } from "./support/paintedFrames";
import { probeEngineOrSkip, requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-jump-unseen.browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  if (!(await probeEngineOrSkip("agent-pane-jump-unseen", "chromium", chromium))) return;
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  type Record = {
    sessionId: string;
    seq: number;
    at: number;
    dir: string;
    kind: string;
    msg: { [key: string]: unknown };
  };
  const update = (sessionUpdate: string, rest: { [key: string]: unknown }) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: { sessionUpdate, ...rest } },
  });
  const chunk = (text: string) => update("agent_message_chunk", { content: { type: "text", text } });
  const LONG = "a long paragraph that keeps each reply taller than a third of the pane. ".repeat(8);

  /// One chat the stand-in holds: its records, its summary, and the reader's cursor.
  type Chat = {
    id: string;
    events: Record[];
    session: { [key: string]: unknown };
    readThrough: number | null;
    seen: number[];
    attaches: number;
  };
  function smallChat(id: string): Chat {
    const events: Record[] = [];
    const start = Date.UTC(2026, 10, 12, 9, 0, 0);
    const push = (dir: string, kind: string, msg: { [key: string]: unknown }) =>
      events.push({ sessionId: id, seq: events.length + 1, at: start + events.length * 1000, dir, kind, msg });
    for (let turn = 1; turn <= 12; turn++) {
      push("mux", "user_message", { text: `Step ${turn}` });
      push("mux", "turn_started", {});
      push(
        "in",
        "agent_message_chunk",
        chunk(turn === 12 ? `${LATEST_TEXT} the last turn read.` : `Reply ${turn}: ${LONG}`),
      );
      push("mux", "turn_result", { status: "completed" });
    }
    const session = {
      sessionId: id,
      cwd: "/home/dev/uploader",
      title: "Seen cursor",
      harness: "claude",
      family: "claude",
      status: "idle",
      turnCount: 12,
      updatedAt: start,
      lastSeq: events.length,
    };
    return { id, events, session, readThrough: null, seen: [], attaches: 0 };
  }
  function bigChat(id: string): Chat {
    const { events, session } = godChat(id, { title: "God chat" });
    return { id, events: events as Record[], session, readThrough: null, seen: [], attaches: 0 };
  }

  let chat: Chat;
  const sockets = new Set<{ send(data: string): void; close(): void }>();
  const lastSeq = () => chat.events.length;
  function answer(method: string, params: { [key: string]: any }): unknown {
    switch (method) {
      case "initialize":
        return {
          protocolVersion: 1,
          _meta: { acpmux: { origin: "local", extensions: [], operations: [], capabilities: ["read-through-v1"] } },
        };
      case "_acpmux/watch":
        return { sessions: [{ ...chat.session, lastSeq: lastSeq() }] };
      case "_acpmux/attach": {
        chat.attaches += 1;
        const { page, hasMore } = newestPage(chat.events, {
          limit: Number(params.limit ?? 2000),
          maxBytes: params.maxBytes,
        });
        return {
          session: { ...chat.session, lastSeq: lastSeq() },
          events: page,
          hasMore,
          lastSeq: lastSeq(),
          pageThrough: lastSeq(),
          presence: { sessionId: chat.id, people: [] },
          turnOpener: null,
          readThrough: chat.readThrough,
        };
      }
      case "_acpmux/events": {
        if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
          const after = chat.events.filter((event) => event.seq > params.afterSeq);
          return {
            events: after.slice(0, 2000),
            hasMore: after.length > 2000,
            lastSeq: lastSeq(),
            pageThrough: lastSeq(),
          };
        }
        const { page, hasMore } = newestPage(chat.events, {
          limit: Number(params.limit ?? 2000),
          beforeSeq: params.beforeSeq,
          maxBytes: params.maxBytes,
        });
        return { events: page, hasMore, lastSeq: lastSeq(), pageThrough: lastSeq() };
      }
      case "_acpmux/seen": {
        // hub/seen.rs `mark_read_through`: forward only, never past the log.
        const seq = Math.min(Number(params.seq), lastSeq());
        chat.seen.push(seq);
        chat.readThrough = Math.max(chat.readThrough ?? -1, seq);
        return { readThrough: chat.readThrough };
      }
      default:
        return {};
    }
  }
  /// A record acpmux logs now, sent live to the attached page.
  function live(dir: string, kind: string, msg: { [key: string]: unknown }): Record {
    const event = { sessionId: chat.id, seq: lastSeq() + 1, at: Date.now(), dir, kind, msg };
    chat.events.push(event);
    for (const socket of sockets)
      socket.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    return event;
  }
  /// `count` finished agent turns, each a reply taller than a third of the view.
  function liveTurns(count: number, tag: string): Record[] {
    const replies: Record[] = [];
    for (let turn = 1; turn <= count; turn++) {
      live("mux", "turn_started", {});
      replies.push(live("in", "agent_message_chunk", chunk(`${tag} ${turn}: ${LONG}`)));
      live("mux", "turn_result", { status: "completed" });
    }
    return replies;
  }

  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  const url = () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    return `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${chat.id}`;
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
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: { [key: string]: any } };
          if (message.id !== undefined)
            ws.send(
              JSON.stringify({ jsonrpc: "2.0", id: message.id, result: answer(message.method, message.params ?? {}) }),
            );
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

  /// Opens the chat with the window's focus under the test's hand (`__focused`): a headless page
  /// always has it. Waits for the latest reply to draw.
  async function open(page?: Page): Promise<Page> {
    const tab = page ?? (await browser!.newPage({ viewport: { width: 900, height: 640 } }));
    if (!page) {
      await installPaintedFrames(tab);
      await tab.addInitScript(() => {
        const w = window as unknown as { __focused: boolean };
        w.__focused = true;
        Document.prototype.hasFocus = () => w.__focused;
        // Jump up is off by default (jumpUp.experiment.ts, #42247): these test the control turned up.
        (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = { "jump-up": "on" };
      });
      await tab.goto(url());
    } else await tab.reload();
    await tab.getByText(LATEST_TEXT).first().waitFor({ timeout: 120_000 });
    await frames(tab, 8);
    return tab;
  }
  const frames = (page: Page, count = 3) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);
  /// The window loses or gets focus; getting it comes with the reader's input on the page.
  const focus = async (page: Page, on: boolean) => {
    await page.evaluate((on) => {
      (window as unknown as { __focused: boolean }).__focused = on;
      window.dispatchEvent(new Event(on ? "focus" : "blur"));
      if (on) window.dispatchEvent(new PointerEvent("pointermove", { clientX: 400, clientY: 300 }));
    }, on);
    await frames(page, 4);
  };
  /// The control and the scroller as drawn.
  const read = (page: Page, rowText?: string) =>
    page.evaluate((rowText) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const control = document.querySelector<HTMLElement>(".acpmux-jump-latest:not(.acpmux-needs-you)");
      const top = scroller.getBoundingClientRect().top;
      const row = rowText
        ? [...document.querySelectorAll<HTMLElement>(".acpmux-row")].find((each) => each.textContent?.includes(rowText))
        : undefined;
      return {
        shown: control?.hasAttribute("data-shown") ?? false,
        jump: control?.getAttribute("data-jump") ?? undefined,
        badge: control?.getAttribute("data-badge") ?? undefined,
        scrollTop: scroller.scrollTop,
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        height: scroller.clientHeight,
        row: row ? row.getBoundingClientRect().top - top : undefined,
      };
    }, rowText);
  const upShown = (page: Page) =>
    page.waitForFunction(
      () => document.querySelector('.acpmux-jump-latest[data-jump="up"][data-shown]') !== null,
      undefined,
      {
        timeout: 30_000,
      },
    );
  /// What `_acpmux/seen` could still send: its throttle is 500 ms (direct.ts SEEN_SEND_MS).
  const settleSeen = (page: Page) =>
    // fixed-wait: an absence check: no `_acpmux/seen` may come within the page's 500 ms throttle.
    page.waitForTimeout(900);

  for (const scale of ["small", "god"] as const) {
    describe(`${scale} chat`, () => {
      const fresh = (tag: string) =>
        (chat =
          scale === "small"
            ? smallChat(`0190a000-0000-7000-8000-00000000${tag}`)
            : bigChat(`0190a000-0000-7000-8000-0000000f${tag}`));

      test("(a) a restart with nothing new shows no arrow and scrolls nothing", async () => {
        fresh("a001");
        const page = await open();
        try {
          // The first open: no cursor yet; the reader attends, so what is in view is seen.
          await settleSeen(page);
          expect(chat.readThrough).not.toBeNull();
          const seenAt = chat.readThrough;
          let at = await read(page);
          expect(at.jump === "up" && at.shown).toBe(false);
          // The daemon restarts and the page reloads (a web update): the same cursor comes back.
          for (const socket of sockets) socket.close();
          await open(page);
          const first = await read(page);
          await frames(page, 12);
          at = await read(page);
          expect(at.shown).toBe(false);
          expect(at.jump).not.toBe("up");
          expect(at.fromEnd).toBeLessThanOrEqual(2);
          // Nothing scrolls after the open: the same offset frame after frame.
          expect(at.scrollTop).toBe(first.scrollTop);
          expect(chat.readThrough).toBe(seenAt);
        } finally {
          await page.close();
        }
      });

      test("(b) unseen turns while the window has no focus: the up arrow, then a press lands the first", async () => {
        fresh("b001");
        const page = await open();
        try {
          await settleSeen(page);
          const before = chat.readThrough!;
          await focus(page, false);
          const replies = liveTurns(5, "Unseen reply");
          await page.getByText("Unseen reply 5:").waitFor();
          await frames(page, 8);
          await settleSeen(page);
          expect(chat.readThrough).toBe(before);
          await upShown(page);
          // Focus and input: the first unseen row is still above the view, so nothing moves.
          await focus(page, true);
          await settleSeen(page);
          expect(chat.readThrough).toBe(before);
          const up = await read(page);
          expect(up.jump).toBe("up");
          expect(up.badge).toBe("dot");
          await page.click('.acpmux-jump-latest[data-jump="up"]');
          await page.waitForFunction(
            () => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              const row = [...document.querySelectorAll<HTMLElement>(".acpmux-row")].find((each) =>
                each.textContent?.includes("Unseen reply 1:"),
              );
              if (!row) return false;
              const at = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
              return at >= 0 && at <= scroller.clientHeight / 4;
            },
            undefined,
            { timeout: 30_000 },
          );
          await frames(page, 6);
          const landed = await read(page, "Unseen reply 1:");
          expect(landed.row!).toBeGreaterThanOrEqual(0);
          expect(landed.row!).toBeLessThanOrEqual(landed.height / 4);
          // In view while attending: seen through it, and the control turns down.
          await settleSeen(page);
          expect(chat.readThrough!).toBeGreaterThanOrEqual(replies[0]!.seq);
          expect((await read(page)).jump).not.toBe("up");
        } finally {
          await page.close();
        }
      });

      test("(c) a reconnect and a notice-only turn move no cursor and bring no arrow", async () => {
        fresh("c001");
        const page = await open();
        try {
          await settleSeen(page);
          const before = chat.readThrough;
          const attaches = chat.attaches;
          for (const socket of sockets) socket.close();
          await page.waitForFunction(() => document.querySelector(".acpmux-scroll") !== null);
          // The page reconnects and attaches again on its own.
          await (async () => {
            for (let tries = 0; tries < 3600 && chat.attaches === attaches; tries += 1) await frames(page, 1);
          })();
          expect(chat.attaches).toBeGreaterThan(attaches);
          live("mux", "host_notice", { text: "This machine was resized." });
          live("mux", "status", { status: "idle", read: true });
          await page.getByText("This machine was resized.").waitFor();
          await frames(page, 8);
          await settleSeen(page);
          expect(chat.readThrough).toBe(before);
          const at = await read(page);
          expect(at.jump === "up" && at.shown).toBe(false);
        } finally {
          await page.close();
        }
      });

      test("(d) scrolling past the unseen rows while attending sees them: the arrow goes", async () => {
        fresh("d001");
        const page = await open();
        try {
          await settleSeen(page);
          await focus(page, false);
          const replies = liveTurns(5, "Read on");
          await page.getByText("Read on 5:").waitFor();
          await frames(page, 8);
          await upShown(page);
          await focus(page, true);
          // Up by hand until the first unseen reply is in view, then down to the latest.
          const box = (await page.locator(".acpmux-scroll").boundingBox())!;
          await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
          for (let step = 0; step < 80; step += 1) {
            const at = await read(page, "Read on 1:");
            if (at.row !== undefined && at.row >= 0 && at.row < at.height / 2) break;
            await page.mouse.wheel(0, -240);
            await frames(page, 2);
          }
          await settleSeen(page);
          expect(chat.readThrough!).toBeGreaterThanOrEqual(replies[0]!.seq);
          for (let step = 0; step < 80; step += 1) {
            if ((await read(page)).fromEnd <= 2) break;
            await page.mouse.wheel(0, 240);
            await frames(page, 2);
          }
          await frames(page, 6);
          await settleSeen(page);
          expect(chat.readThrough!).toBeGreaterThanOrEqual(replies.at(-1)!.seq);
          const at = await read(page);
          expect(at.jump === "up" && at.shown).toBe(false);
        } finally {
          await page.close();
        }
      });
    });
  }
});
