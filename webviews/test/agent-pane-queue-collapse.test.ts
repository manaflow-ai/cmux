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
import { installPaintedFrames } from "./support/paintedFrames";
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
        } else if (params.op === "update") {
          entry.prompt = String(params.text);
          event(ws, "queue_updated", { promptId: entry.promptId, text: entry.prompt });
        } else if (params.op === "send_now") {
          queue = queue.filter((q) => q !== entry);
          event(ws, "dequeued", { promptId: entry.promptId });
          event(ws, "user_message", { text: entry.prompt, promptId: entry.promptId, turnId: "turn-1", steer: true });
        }
        return { ok: true, ...(params.op === "send_now" ? { sent: "steer" } : {}) };
      }
      case "_acpmux/queue_remove": {
        edits.push({ op: "remove", promptId: params.promptId });
        const before = queue.length;
        queue = queue.filter((q) => q.promptId !== params.promptId);
        if (queue.length === before) return { removed: false };
        event(ws, "queue_removed", { promptId: params.promptId });
        return { removed: true };
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
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(`http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${SESSION}`);
    await page.locator('.acpmux-queued[data-prompt-id="q-1"]').waitFor();
    return page;
  }

  /// What the queue shows: each row's text (rows carry no number, Leo 2026-10-21), then its fold
  /// control's label and state.
  const shown = (page: Page) =>
    page.evaluate(() => {
      const list = document.querySelector(".acpmux-composer-queue");
      const rows = [...(list?.querySelectorAll<HTMLElement>(".acpmux-queued") ?? [])].map(
        (row) => row.querySelector(".acpmux-queued-text")?.textContent ?? "",
      );
      const fold = document.querySelector<HTMLButtonElement>("button[aria-expanded].acpmux-queue-fold");
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
    test("a queued row's actions centre on its first line (layout pass, 2026-10-20)", async () => {
      const page = await openChat(["one line"]);
      const row = page.locator('.acpmux-queued[data-prompt-id="q-1"]');
      await row.hover();
      const offset = await row.evaluate((li) => {
        const middle = (el: Element) => {
          const box = el.getBoundingClientRect();
          return box.top + box.height / 2;
        };
        // The text is one 18px line.
        return middle(li.querySelector(".acpmux-queued-action")!) - middle(li.querySelector(".acpmux-queued-text")!);
      });
      expect(Math.abs(offset)).toBeLessThanOrEqual(0.5);
      await page.close();
    });

    test("a glass queue band stays glass with the prompt focused, in each top strip (layout pass, 2026-10-20)", async () => {
      const page = await openChat(["one line"]);
      await page.locator(".acpmux-composer-prompt").click();
      // What the see-through rule sets (composerStates.css); a CI host may ask for reduced transparency.
      await page.evaluate(() => document.documentElement.style.setProperty("--acpmux-queue-glass", "60%"));
      const alphas: Record<string, number> = {};
      for (const strip of ["", "tray", "bump", "plain"]) {
        alphas[strip || "none"] = await page.evaluate((strip) => {
          const root = document.documentElement;
          if (strip) root.setAttribute("data-top-strip", strip);
          else root.removeAttribute("data-top-strip");
          const fill = getComputedStyle(document.querySelector(".acpmux-composer-queue")!).backgroundColor;
          // rgba(r, g, b, a) or color(srgb r g b / a); rgb(r, g, b) or color(srgb r g b) is opaque.
          const alpha = (fill.match(/^rgba\(.*,\s*([\d.]+%?)\)$/) ?? fill.match(/\/\s*([\d.]+%?)\s*\)$/))?.[1];
          if (alpha === undefined) return 1;
          return alpha.endsWith("%") ? parseFloat(alpha) / 100 : parseFloat(alpha);
        }, strip);
      }
      expect(await page.evaluate(() => !!document.activeElement?.closest(".acpmux-composer-prompt"))).toBe(true);
      // Glass, focused or not: never solid; the plain strip has no fill at all.
      expect({
        none: alphas.none < 1,
        tray: alphas.tray < 1,
        bump: alphas.bump < 1,
        plain: alphas.plain,
      }).toEqual({ none: true, tray: true, bump: true, plain: 0 });
      await page.close();
    });

    test("six queued prompts fold behind '4 more queued', which opens and closes in place", async () => {
      const page = await openChat(PROMPTS);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      expect(await shown(page)).toEqual({ rows: ["one", "two"], fold: "4 more queued (false)" });

      // ↑ from the empty prompt reaches the fold first; Return opens it, and it keeps focus.
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("fold");
      await page.keyboard.press("Enter");
      expect(await shown(page)).toEqual({
        rows: ["one", "two", "three", "four", "five", "six"],
        fold: "Show less (true)",
      });
      expect(await focused(page)).toBe("fold");
      // Space closes it; ↑ goes on to the last row it shows, ↓ comes back, and ↓ again to the prompt.
      await page.keyboard.press("Space");
      expect(await shown(page)).toEqual({ rows: ["one", "two"], fold: "4 more queued (false)" });
      await page.keyboard.press("ArrowUp");
      expect(await focused(page)).toBe("q-2");
      await page.keyboard.press("ArrowDown");
      expect(await focused(page)).toBe("fold");
      await page.keyboard.press("ArrowDown");
      expect(await page.evaluate(() => !!document.activeElement?.closest(".acpmux-composer-prompt"))).toBe(true);

      // A click opens it too.
      await page.locator(".acpmux-queue-fold").click();
      expect((await shown(page)).rows).toHaveLength(6);
      await page.locator(".acpmux-queue-fold").click();
      expect((await shown(page)).fold).toBe("4 more queued (false)");
      await page.close();
    });

    test("queue growth uses the structural motion token while its fitted height changes", async () => {
      const page = await openChat(PROMPTS);
      const before = await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        const style = getComputedStyle(list);
        return {
          height: list.getBoundingClientRect().height,
          transition: style.transition,
          ready: list.hasAttribute("data-fit-ready"),
          animations: list.getAnimations().length,
        };
      });
      expect(before.transition).toContain("max-height");
      expect(before.ready).toBe(true);
      expect(before.animations).toBe(0);
      await page.locator(".acpmux-queue-fold").click();
      await page.waitForFunction(
        (height) =>
          document.querySelector<HTMLElement>(".acpmux-composer-queue")!.getBoundingClientRect().height > height + 1,
        before.height,
      );
      const after = await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        return list.getBoundingClientRect().height;
      });
      expect(after).toBeGreaterThan(before.height);
      await page.close();
    });

    test("an opened long queue keeps Show less and the focused row in sight, never a half row (capture, 2026-10-15)", async () => {
      // The real-app capture at 90721dc: five queued, opened, the list stayed capped at 132px, row 4
      // cut through its text and Show less (focused) below the edge.
      const page = await openChat(["one", "two", "three", "four", "five", "six", "seven", "eight"]);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 8);
      /// Where the focused element sits against the list's own edges, the fold (drawn over the
      /// rows it pins below) and the page; and whether any row the list shows is cut at an edge.
      const sight = () =>
        page.evaluate(
          () =>
            new Promise<Record<string, unknown>>((resolve) =>
              window.cmuxPaintFrame().then(() =>
                window.cmuxPaintFrame().then(() => {
                  const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
                  const box = list.getBoundingClientRect();
                  const fold = document.querySelector<HTMLElement>(".acpmux-queue-fold")!.getBoundingClientRect();
                  const focused = document.activeElement as HTMLElement;
                  // Rows show between the list's top and bottom edges, never under the fold.
                  const top = box.top;
                  const edge = Math.min(box.bottom, fold.top);
                  const inside = (rect: DOMRect) =>
                    rect.top >= top - 1 && rect.bottom <= edge + 1 && rect.bottom <= innerHeight + 1;
                  // The fold: on the page, and clear of every row the list shows.
                  const foldClear = fold.top >= box.bottom - 1 && fold.bottom <= innerHeight + 1;
                  const isFold = focused.classList.contains("acpmux-queue-fold");
                  const rect = focused.getBoundingClientRect();
                  // A row the list does not draw (cut while it scrolls) is not a half row.
                  const cut = [...list.querySelectorAll<HTMLElement>(".acpmux-queued")]
                    .filter((row) => getComputedStyle(row).opacity !== "0")
                    .map((row) => row.getBoundingClientRect())
                    .filter((row) => row.bottom > top + 1 && row.top < edge - 1)
                    .filter((row) => row.top < top - 1 || row.bottom > edge + 1).length;
                  resolve({
                    focused: focused.dataset.promptId ?? (isFold ? "fold" : focused.className),
                    inSight: isFold ? foldClear : inside(rect),
                    foldInSight: foldClear,
                    wholeRows: cut === 0,
                  });
                }),
              ),
            ),
        );
      expect(await sight()).toEqual({ focused: "fold", inSight: true, foldInSight: true, wholeRows: true });
      /// The same, but where the list rests mid-scroll a row its edge cuts may show.
      const steady = async () => {
        const { wholeRows: _, ...rest } = await sight();
        return rest;
      };
      // ↑ through every row and ↓ back to the fold: the focused one is always whole and in sight. A
      // row the edge cuts mid-scroll still draws (f1a737b blanked it, which read as a missing prompt),
      // so whole rows are asked of the list at rest at its top, above.
      for (let i = 8; i >= 1; i--) {
        await page.keyboard.press("ArrowUp");
        expect(await steady()).toEqual({ focused: `q-${i}`, inSight: true, foldInSight: true });
      }
      for (let i = 2; i <= 8; i++) {
        await page.keyboard.press("ArrowDown");
        expect(await steady()).toEqual({ focused: `q-${i}`, inSight: true, foldInSight: true });
      }
      await page.keyboard.press("ArrowDown");
      expect(await steady()).toEqual({ focused: "fold", inSight: true, foldInSight: true });
      await page.close();
    });

    test("a long row opened in a folded queue never runs under the fold (capture, 2026-10-15)", async () => {
      // The capture at 935dada: the folded queue's first row opened to its whole text ran under the
      // pinned "6 more queued", and row 2 hid behind it.
      const long = "a queued prompt long enough to take several lines once it is opened whole ".repeat(8);
      const page = await openChat([long, "two", "three", "four", "five", "six", "seven", "eight"]);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      await page.locator('.acpmux-queued[data-prompt-id="q-1"] .acpmux-queued-text').click();
      await page.locator('.acpmux-queued[data-prompt-id="q-1"] .acpmux-queued-text[data-open]').waitFor();
      const layout = await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!.getBoundingClientRect();
        const fold = document.querySelector<HTMLElement>(".acpmux-queue-fold")!;
        const box = fold.getBoundingClientRect();
        // What draws at each point of the fold is the fold itself, never a row's text.
        const hit = [0.1, 0.5, 0.9].map((x) => {
          const at = document.elementFromPoint(box.left + box.width * x, box.top + box.height / 2);
          return !!at && (at === fold || fold.contains(at) || !at.closest(".acpmux-queued"));
        });
        return { foldBelowList: box.top >= list.bottom - 1, hit };
      });
      expect(layout).toEqual({ foldBelowList: true, hit: [true, true, true] });
      await page.close();
    });

    test("opening the fold grows the bottom stack by about one row at most (capture, 2026-10-15)", async () => {
      // The capture at 935dada: opening eight queued prompts took the transcript from 312 to 156 px.
      const page = await openChat(["one", "two", "three", "four", "five", "six", "seven", "eight"]);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      const height = () =>
        page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-composer")!.getBoundingClientRect().height);
      const folded = await height();
      await page.locator(".acpmux-queue-fold").click();
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 8);
      const opened = await height();
      expect(Math.abs(opened - folded)).toBeLessThanOrEqual(40);
      await page.close();
    });

    /// The queue list's rows as drawn: how many it shows cut at its edges (a row it hides whole
    /// does not count), and whether the focused row
    /// is whole and in sight.
    const drawn = (page: Page) =>
      page.evaluate(
        () =>
          new Promise<Record<string, unknown>>((resolve) =>
            window.cmuxPaintFrame().then(() =>
              window.cmuxPaintFrame().then(() => {
                const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
                const box = list.getBoundingClientRect();
                const shows = (el: Element) => {
                  const r = el.getBoundingClientRect();
                  return (
                    getComputedStyle(el).visibility !== "hidden" &&
                    getComputedStyle(el).opacity !== "0" &&
                    r.bottom > box.top + 1 &&
                    r.top < box.bottom - 1
                  );
                };
                const whole = (r: DOMRect) => r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
                const parts = [...list.querySelectorAll<HTMLElement>(".acpmux-queued")];
                // A row whose text runs out of it (over the next row) is cut too.
                const spills = (el: Element) =>
                  [...el.querySelectorAll(".acpmux-queued-text")].some(
                    (text) => text.getBoundingClientRect().bottom > el.getBoundingClientRect().bottom + 1,
                  );
                const cut = parts.filter(
                  (el) => shows(el) && (!whole(el.getBoundingClientRect()) || spills(el)),
                ).length;
                const focused = document.activeElement as HTMLElement;
                const row = focused.closest<HTMLElement>(".acpmux-queued");
                resolve({
                  cut,
                  focusedWhole: row ? shows(row) && whole(row.getBoundingClientRect()) : true,
                });
              }),
            ),
          ),
      );
    const clean = { cut: 0, focusedWhole: true };

    test("an opened queue with a two-line row shows whole rows only, no row under another (capture, 2026-10-15)", async () => {
      // The capture at 436917b: opened, a two-line first row left a sliver of row 3 over Show less,
      // and after ↑↑↑ row 5 drew over the pinned "Queued" header.
      const long = "words that wrap across the row ".repeat(12);
      const page = await openChat([long, "two", "three", "four", "five", "six", "seven", "eight"]);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 8);
      expect(await drawn(page)).toEqual(clean);
      for (let i = 8; i >= 1; i--) {
        await page.keyboard.press("ArrowUp");
        expect({ i, ...(await drawn(page)), cut: 0 }).toEqual({ i, ...clean });
      }
      for (let i = 2; i <= 8; i++) {
        await page.keyboard.press("ArrowDown");
        expect({ i, ...(await drawn(page)), cut: 0 }).toEqual({ i, ...clean });
      }
      await page.close();
    });

    test("opening the queue lands at its top: row 1 in sight, nothing blanked (capture, 2026-10-15)", async () => {
      // The capture at f1a737b: the first frame after ↑ then Return showed rows 2-5, the header and
      // row 1 scrolled away, and a blank band where rows were not drawn.
      const long = "words that wrap across the row ".repeat(12);
      const names = ["fruits", "vegetables", "rivers", "birds", "trees", "planets", "colors"];
      const page = await openChat([long, ...names.map((name) => `then name three ${name}.`)]);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      await page.locator(".acpmux-composer-prompt").click();
      await page.keyboard.press("ArrowUp");
      await page.keyboard.press("Enter");
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 8);
      // Past any snap or scroll that settles after the first frames: no animation left running and
      // the list's scroll position held over three painted frames.
      await page.evaluate(async () => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        const finite = () =>
          document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
        for (let tries = 0; tries < 20; tries++) {
          await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
          await new Promise<void>((resolve) => {
            let last = -1;
            let still = 0;
            window.cmuxAfterPaint(() => {
              still = list.scrollTop === last ? still + 1 : 0;
              last = list.scrollTop;
              if (still < 2) return true;
              resolve();
              return false;
            });
          });
          if (finite().every((animation) => animation.playState !== "running")) return;
        }
      });
      const top = await page.evaluate(() => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        const box = list.getBoundingClientRect();
        const inSight = (el: Element | null) => {
          const r = el?.getBoundingClientRect();
          return !!r && r.top >= box.top - 1 && r.bottom <= box.bottom + 1;
        };
        return {
          scrollTop: list.scrollTop,
          row1: inSight(list.querySelector('[data-prompt-id="q-1"]')),
          blanked: [...list.querySelectorAll("li")].filter((li) => getComputedStyle(li).opacity === "0").length,
        };
      });
      expect(top).toEqual({ scrollTop: 0, row1: true, blanked: 0 });
      await page.close();
    });

    test("a folded queue with a long row opened shows only whole rows above the fold (capture, 2026-10-15)", async () => {
      // The capture at 436917b: the first row opened whole, and row 2 showed as a sliver above the fold.
      // Lengths from three lines to six, so row 2 meets the list's edge at some of them.
      for (const lines of [2, 3, 4, 5, 6]) {
        const long = "after the story, check three things in this chat and answer each in one short line ".repeat(
          lines,
        );
        const page = await openChat([
          long,
          "then name three fruits.",
          "three",
          "four",
          "five",
          "six",
          "seven",
          "eight",
        ]);
        await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
        await page.locator('.acpmux-queued[data-prompt-id="q-1"] .acpmux-queued-text').click();
        await page.locator('.acpmux-queued[data-prompt-id="q-1"] .acpmux-queued-text[data-open]').waitFor();
        expect({ lines, ...(await drawn(page)) }).toEqual({ lines, ...clean });
        await page.close();
      }
    });

    /// Opens an eight-prompt queue with a click on its fold.
    async function openedQueue(): Promise<Page> {
      const page = await openChat(["one", "two", "three", "four", "five", "six", "seven", "eight"]);
      await page.locator(".acpmux-queue-fold").click();
      await page.waitForFunction(() => document.querySelectorAll(".acpmux-queued").length === 8);
      return page;
    }
    /// Where the opened list rests once any snap or scroll settles: at its end or not, and whether
    /// its last row shows whole. Settled is ten painted frames running with no scroll event on the
    /// list and no animation running, so a snap back (a scroll that ends and then moves again)
    /// starts the count over and is read where it lands.
    const resting = (page: Page) =>
      page.evaluate(async () => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        let moved = true;
        const mark = () => (moved = true);
        list.addEventListener("scroll", mark);
        list.addEventListener("scrollend", mark);
        await new Promise<void>((resolve) => {
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = moved || running ? 0 : still + 1;
            moved = false;
            if (still < 10 && ++frames < 600) return true;
            resolve();
            return false;
          });
        });
        list.removeEventListener("scroll", mark);
        list.removeEventListener("scrollend", mark);
        const box = list.getBoundingClientRect();
        const last = [...list.querySelectorAll(".acpmux-queued")].at(-1)!.getBoundingClientRect();
        return {
          atEnd: list.scrollTop >= list.scrollHeight - list.clientHeight - 1,
          lastWhole: last.top >= box.top - 1 && last.bottom <= box.bottom + 1,
        };
      });

    test("an opened queue scrolled to its end stays there, its last row whole (Leo, 2026-10-20)", async () => {
      // Leo: the queue "scrolls to the bottom then shoots back up", and the last row is cut off.
      // Every row snapped its top to the list's, and the list's end is no row's top.
      const page = await openedQueue();
      const box = (await page.locator(".acpmux-composer-queue").boundingBox())!;
      await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
      await page.mouse.wheel(0, 2000);
      expect(await resting(page)).toEqual({ atEnd: true, lastWhole: true });
      await page.locator(".acpmux-composer-queue").evaluate((list) => (list.scrollTop = 0));
      await page.locator(".acpmux-composer-queue").evaluate((list) => (list.scrollTop = list.scrollHeight));
      expect(await resting(page)).toEqual({ atEnd: true, lastWhole: true });
      await page.close();
    });

    /// Rests the opened list half a row down, so its bottom edge cuts row 4, and returns the middle
    /// of the shown part of that row's control that `control` selects.
    async function cutRowAction(page: Page, control: string) {
      return page.evaluate((control) => {
        const list = document.querySelector<HTMLElement>(".acpmux-composer-queue")!;
        const rows = [...list.querySelectorAll<HTMLElement>(".acpmux-queued")];
        list.scrollTop = rows[0].getBoundingClientRect().height / 2;
        const box = list.getBoundingClientRect();
        const cut = rows.find((row) => {
          const rect = row.getBoundingClientRect();
          return rect.top < box.bottom - 2 && rect.bottom > box.bottom + 1;
        })!;
        const button = cut.querySelector<HTMLElement>(control)!.getBoundingClientRect();
        return {
          id: cut.dataset.promptId!,
          x: button.left + button.width / 2,
          y: (button.top + Math.min(button.bottom, box.bottom)) / 2,
        };
      }, control);
    }

    test("Remove and Edit on a row the list's edge cuts do what they say (Leo, 2026-10-20)", async () => {
      // The press focused the row, which scrolled the list to show it whole before the release: the
      // click landed on another row or none.
      const page = await openedQueue();
      const remove = await cutRowAction(page, '[data-action="delete"]');
      await page.mouse.click(remove.x, remove.y);
      await page.waitForFunction((id) => !document.querySelector(`.acpmux-queued[data-prompt-id="${id}"]`), remove.id, {
        timeout: 5_000,
      });
      expect(edits).toEqual([{ op: "remove", promptId: remove.id }]);

      // Edit message is in the row's ⋯ menu: the press on the ⋯ must open that row's menu.
      const edit = await cutRowAction(page, '[data-menu="queued-more"]');
      await page.mouse.click(edit.x, edit.y);
      await page.getByRole("menuitem", { name: /Edit message/ }).click();
      const field = page.locator(`.acpmux-queued[data-prompt-id="${edit.id}"] textarea`);
      await field.waitFor({ timeout: 5_000 });
      await page.keyboard.press("ControlOrMeta+a");
      await page.keyboard.type("edited");
      await page.keyboard.press("Enter");
      await page.waitForFunction(
        (id) =>
          document.querySelector(`.acpmux-queued[data-prompt-id="${id}"] .acpmux-queued-text`)?.textContent ===
          "edited",
        edit.id,
        { timeout: 5_000 },
      );
      expect(edits).toEqual([
        { op: "remove", promptId: remove.id },
        { op: "update", promptId: edit.id, text: "edited" },
      ]);
      await page.close();
    });

    test("sending the next prompt keeps the fold's count right; a move into the fold opens it", async () => {
      const page = await openChat(PROMPTS);
      await page.locator(".acpmux-queue-fold").waitFor({ timeout: 10_000 });
      const row = page.locator('.acpmux-queued[data-prompt-id="q-1"]');
      await row.hover();
      await row.getByRole("button", { name: "Steer" }).click();
      await page.waitForFunction(() => !document.querySelector('.acpmux-queued[data-prompt-id="q-1"]'));
      expect(await shown(page)).toEqual({ rows: ["two", "three"], fold: "3 more queued (false)" });

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
        rows: ["two", "four", "three", "five", "six"],
        fold: "Show less (true)",
      });
      await page.close();
    });
  });
});
