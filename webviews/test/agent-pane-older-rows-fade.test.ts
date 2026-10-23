// l10n-allow-file: test fixture prompts, not shipped UI.
// Older turns fade in as the reader first sees them (cx-2lv1k): a page of older history lands above
// the view while the reader scrolls up, and each of its rows fades in once, the first time it comes
// into view at the top edge. The rows the chat opened with, rows already seen, and live rows (which
// keep their own entrance) never take that fade, and Reduce Motion draws older rows in full ink at once.
//
// Real Chromium from Playwright; skipped where it is not installed (the hosted webviews job).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-older-rows-fade.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-older-rows-fade: skipping (run `bunx playwright install chromium`)");
    describe.skip("older rows fade", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");

  const CHAT = "0190a000-0000-7000-8000-00000000f4de";
  const START = Date.UTC(2026, 9, 1, 9, 0, 0);
  const TURNS = 160;
  const update = (update: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update },
  });
  const chunk = (text: string) => update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } });
  type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
  const events: Event[] = [];
  const record = (dir: string, kind: string, msg: Record<string, unknown>): Event => {
    const event = { sessionId: CHAT, seq: events.length + 1, at: START + events.length * 1000, dir, kind, msg };
    events.push(event);
    return event;
  };
  for (let n = 1; n <= TURNS; n++) {
    record("mux", "user_message", { text: `Question ${n}` });
    record("mux", "turn_started", {});
    record("in", "agent_message_chunk", chunk(`Answer ${n}: the build on this branch passes, `));
    record("in", "agent_message_chunk", chunk("and the checks on the merged head are green."));
    record("mux", "turn_result", { status: "completed" });
  }
  const lastSeq = events.length;
  const session = {
    sessionId: CHAT,
    cwd: "/home/dev/cmux",
    title: "Long chat",
    harness: "claude",
    family: "claude",
    status: "ready",
    turnCount: TURNS,
    updatedAt: START,
    lastSeq,
  };

  /// acpmux's paging: the newest `limit` records before `beforeSeq`, or the first `limit` after `afterSeq`.
  function page(params: Record<string, any>) {
    const limit = Math.min(Number(params.limit ?? 2000), 150);
    const held = events.slice(0, lastSeq);
    if (typeof params.afterSeq === "number" && params.beforeSeq === undefined) {
      const after = held.filter((event) => event.seq > params.afterSeq);
      return { events: after.slice(0, limit), hasMore: after.length > limit, lastSeq };
    }
    const before = held.filter((event) => event.seq < (params.beforeSeq ?? Infinity));
    return { events: before.slice(Math.max(0, before.length - limit)), hasMore: before.length > limit, lastSeq };
  }
  /// The oldest turn whose prompt the chat opened with: every turn from it on is a first-open row.
  let openedFrom = Infinity;
  function answer(method: string, params: Record<string, any>): unknown {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach": {
        const result = page(params);
        for (const event of result.events)
          if (event.kind === "user_message")
            openedFrom = Math.min(openedFrom, Number(String(event.msg.text).replace("Question ", "")));
        return { session, ...result };
      }
      case "_acpmux/events":
        return page(params);
      default:
        return null;
    }
  }

  let inflight = 0;
  const sockets = new Set<{ send(data: string): void }>();
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
        open(ws) {
          sockets.add(ws);
        },
        close(ws) {
          sockets.delete(ws);
        },
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string; params?: Record<string, any> };
          if (message.id === undefined) return;
          const result = answer(message.method, message.params ?? {});
          inflight++;
          setTimeout(() => {
            ws.send(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }));
            inflight--;
          }, 40);
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

  type Fade = { id: string; text: string };
  /// Opens the chat with every row-level animation start recorded: the row, its text, its animation.
  async function open(reducedMotion: "reduce" | "no-preference"): Promise<Page> {
    const page = await browser!.newPage({ viewport: { width: 900, height: 760 }, reducedMotion });
    await installPaintedFrames(page);
    await page.addInitScript(() => {
      const fades: { id: string; text: string; name: string }[] = [];
      (window as unknown as { __rowAnimations: typeof fades }).__rowAnimations = fades;
      document.addEventListener(
        "animationstart",
        (event) => {
          const row = event.target as HTMLElement;
          if (!row.classList?.contains("acpmux-row")) return;
          // A message's age ("3 weeks ago", #23769) runs straight on from its text, so "Question 130"
          // would read as turn 1303: the row's text without it.
          const words = row.cloneNode(true) as HTMLElement;
          for (const time of words.querySelectorAll("time")) time.remove();
          fades.push({ id: row.dataset.rowId ?? "", text: words.textContent ?? "", name: event.animationName });
        },
        true,
      );
    });
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${CHAT}`);
    await page.getByText(`Question ${TURNS}`, { exact: true }).waitFor({ timeout: 60_000 });
    await settle(page);
    await animationsDone(page);
    const box = (await page.locator(".acpmux-scroll").boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    return page;
  }
  /// The older-history fades so far: row-level animations other than a live row's entrance.
  const olderFades = async (page: Page): Promise<Fade[]> =>
    (
      await page.evaluate(
        () => (window as unknown as { __rowAnimations: { id: string; text: string; name: string }[] }).__rowAnimations,
      )
    )
      .filter((animation) => animation.name !== "cv-enter" && animation.name !== "cv-enter-fade")
      .map(({ id, text }) => ({ id, text }));
  /// The turn a row belongs to, from its prompt or its answer (a "Worked for" footer has none).
  const turnOf = (text: string) => {
    const match = /(?:Question|Answer) (\d+)/.exec(text);
    return match ? Number(match[1]) : undefined;
  };
  /// Until the daemon has answered every request and the transcript has held its scroll position
  /// over three painted frames.
  const settle = async (page: Page) => {
    for (let tries = 0; tries < 50; tries++) {
      await page.evaluate(
        () =>
          new Promise<void>((resolve) => {
            let last = -1;
            let still = 0;
            window.cmuxAfterPaint(() => {
              const top = document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop;
              still = top === last ? still + 1 : 0;
              last = top;
              if (still < 2) return true;
              resolve();
              return false;
            });
          }),
      );
      if (inflight === 0) return;
    }
  };
  /// Until every row animation running has finished (an older row's fade, a live row's entrance)
  /// and two more frames have painted with none started.
  const animationsDone = async (page: Page) => {
    for (let tries = 0; tries < 20; tries++) {
      const running = await page.evaluate(async () => {
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
        await window.cmuxPaintFrame();
        await window.cmuxPaintFrame();
        return finite().filter((animation) => animation.playState === "running").length;
      });
      if (running === 0) return;
    }
  };
  /// Wheels up until a prompt older than `turn` is in view.
  async function scrollUpTo(page: Page, turn: number) {
    for (let step = 0; step < 300; step++) {
      const seen = await page.evaluate((turn) => {
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        return [...document.querySelectorAll<HTMLElement>(".cv-user__bubble")].some((bubble) => {
          const box = bubble.getBoundingClientRect();
          const n = Number((bubble.textContent ?? "").replace("Question ", ""));
          return n < turn && box.bottom > view.top && box.top < view.bottom;
        });
      }, turn);
      if (seen) return;
      await page.mouse.wheel(0, -300);
      await settle(page);
    }
    throw new Error(`never scrolled to a turn before ${turn}`);
  }

  test("rows of an older page fade in once as they come into view; opened and live rows do not", async () => {
    const page = await open("no-preference");
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    expect(openedFrom).toBeLessThan(TURNS);
    // Opening draws its rows in full ink: nothing fades.
    expect(await olderFades(page)).toEqual([]);

    // Up through the rows the chat opened with and well into the older pages.
    const target = openedFrom - 20;
    await scrollUpTo(page, target);
    await animationsDone(page);
    const fades = await olderFades(page);
    const turns = fades.map((fade) => turnOf(fade.text)).filter((turn) => turn !== undefined);
    // Rows from older pages faded as they came in, and only those.
    expect(turns.some((turn) => turn < openedFrom)).toBe(true);
    expect(turns.filter((turn) => turn >= openedFrom)).toEqual([]);
    // The fade is opacity only, and settles to full ink.
    const settled = await page.evaluate(() => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter((row) => {
          const box = row.getBoundingClientRect();
          return box.bottom > view.top + 40 && box.top < view.bottom;
        })
        .map((row) => getComputedStyle(row).opacity);
    });
    expect(new Set(settled)).toEqual(new Set(["1"]));

    // Down and back up over the same rows: each older row faded once, and does not again.
    for (let step = 0; step < 6; step++) {
      await page.mouse.wheel(0, 300);
      await settle(page);
    }
    for (let step = 0; step < 6; step++) {
      await page.mouse.wheel(0, -300);
      await settle(page);
    }
    await animationsDone(page);
    const again = await olderFades(page);
    const ids = again.map((fade) => fade.id);
    expect(ids.length - new Set(ids).size).toBe(0);
    expect(again.length).toBe(new Set([...fades.map((fade) => fade.id), ...ids]).size);

    // Back at the latest message, a live turn arrives: it keeps its own entrance and never the older fade.
    const before = (await olderFades(page)).length;
    await page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      node.scrollTop = node.scrollHeight;
    });
    await settle(page);
    await animationsDone(page);
    const scrolledDown = (await olderFades(page)).length;
    const send = (dir: string, kind: string, msg: Record<string, unknown>) => {
      const event = record(dir, kind, msg);
      for (const socket of sockets)
        socket.send(JSON.stringify({ jsonrpc: "2.0", method: "_acpmux/event", params: event }));
    };
    send("mux", "user_message", { text: "Question live" });
    send("mux", "turn_started", {});
    send("in", "agent_message_chunk", chunk("Live answer: the release compile is green."));
    send("mux", "turn_result", { status: "completed" });
    await page.getByText("Question live", { exact: true }).waitFor({ timeout: 10_000 });
    await animationsDone(page);
    const live = (await olderFades(page)).slice(scrolledDown);
    expect(live.filter((fade) => fade.text.includes("live") || fade.text.includes("Live"))).toEqual([]);
    expect(scrolledDown).toBeGreaterThanOrEqual(before);
    expect(errors).toEqual([]);
    await page.close();
  });

  test("Reduce Motion draws rows of an older page in full ink at once", async () => {
    events.length = lastSeq;
    const page = await open("reduce");
    const errors: string[] = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await scrollUpTo(page, openedFrom - 20);
    // No frame of a fade: every older row in view is already in full ink, with no animation on it.
    const rows = await page.evaluate(() => {
      const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return [...document.querySelectorAll<HTMLElement>(".acpmux-row")]
        .filter((row) => {
          const box = row.getBoundingClientRect();
          return box.bottom > view.top && box.top < view.bottom;
        })
        .map((row) => ({
          opacity: getComputedStyle(row).opacity,
          animations: row.getAnimations().length,
        }));
    });
    expect(rows.length).toBeGreaterThan(0);
    expect(rows.filter((row) => row.opacity !== "1" || row.animations > 0)).toEqual([]);
    expect(await olderFades(page)).toEqual([]);
    expect(errors).toEqual([]);
    await page.close();
  });
});
