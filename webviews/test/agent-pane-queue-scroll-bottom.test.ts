// l10n-allow-file: test fixture prompts, not shipped UI.
// The transcript's end under the queue and the composer (Leo 2026-10-21: "there's something just a
// bit awkward about the UI of this queuing and steering and expanding and, like, scrolling. It
// doesn't scroll to the very bottom ... it's almost like it's allowed to, but then it just shoots
// back up ... it cuts off at the bottom").
//
// - The queue opened and the view scrolled to its end: the latest row ends above the stack, whole,
//   and stays there.
// - The queue closed at the latest row: the room under the last row shrinks with the stack in the
//   same frame. A queued card the fold hides has not left the queue: the view keeps no room for it
//   (VirtualTranscript `floor`, kept for a sent prompt) that would hold a hole above the stack for a
//   second and then glide the rows down.
// - A new line in the composer leaves the transcript's distance from its end as it was, at the
//   latest row and scrolled up (#23302).
// - The wheel beside the composer, left and right of the queue, its fold and the card, scrolls the
//   transcript (#23243).
//
// One chat of 40 finished turns and a running one (support/papercutChat.ts), six prompts queued (two
// shown, "4 more queued"), through the pane's dev entry and a stand-in acpmux. Real Chromium and
// WebKit (the app's engine) with real wheel and key events; every read is of a painted frame
// (support/paintedFrames.ts). CI fails the file when it cannot launch them (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-queue-scroll-bottom.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-queue-scroll-bottom.test.ts", async () => {
  setDefaultTimeout(300_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`agent-pane-queue-scroll-bottom: skipping ${engine[0]}`);
    }
  }
  if (engines.length === 0) {
    describe.skip("queue scroll bottom", () => test("browsers", () => {}));
    return;
  }

  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const queue = ["one", "two", "three", "four", "five", "six"].map((word, index) => ({
    promptId: `q-${index + 1}`,
    prompt: `The ${word} queued prompt, about the parser and its tests`,
  }));
  const { events, session } = papercutEvents({
    turns: 40,
    running: true,
    session: { steering: true, queuePaused: false, queued: queue.length, queue },
  });
  const answer = (method: string): unknown => {
    switch (method) {
      case "initialize":
        return { protocolVersion: 1, _meta: { acpmux: { origin: "local", extensions: [], operations: [] } } };
      case "_acpmux/watch":
        return { sessions: [session] };
      case "_acpmux/attach":
        return { session, lastSeq: events.length, events, hasMore: false };
      case "_acpmux/events":
        return { events: [], hasMore: false, lastSeq: events.length };
      default:
        return null;
    }
  };
  const browsers = new Map<string, Browser>();
  let daemon: ReturnType<typeof Bun.serve> | undefined;
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  beforeAll(async () => {
    daemon = Bun.serve({
      port: 0,
      hostname: "127.0.0.1",
      fetch(request, server) {
        return server.upgrade(request, { data: undefined }) ? undefined : new Response("acpmux", { status: 426 });
      },
      websocket: {
        message(ws, raw) {
          const message = JSON.parse(String(raw)) as { id?: number; method: string };
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
    for (const [name, engine] of engines) browsers.set(name, await engine.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Where the transcript's end is, in a painted frame: `fromEnd` is the scroller's distance from its
  /// end, `gap` how far the last row ends above the bottom stack (negative: under it).
  type Placement = { top: number; fromEnd: number; gap: number };
  /// The placement in each painted frame for `ms`, starting with the next one; `act` runs first.
  async function paintedFor(page: Page, ms: number, act?: () => Promise<unknown>): Promise<Placement[]> {
    const done = page.evaluate(
      (ms) =>
        new Promise<Placement[]>((resolve) => {
          const out: Placement[] = [];
          let start: number | undefined;
          window.cmuxAfterPaint((frame) => {
            start ??= frame;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const rows = document.querySelectorAll<HTMLElement>(".acpmux-thread .acpmux-row");
            const dock = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock")!;
            out.push({
              top: scroller.scrollTop,
              fromEnd: scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight,
              gap: dock.getBoundingClientRect().top - rows[rows.length - 1].getBoundingClientRect().bottom,
            });
            if (frame - start < ms) return true;
            resolve(out);
            return false;
          });
        }),
      ms,
    );
    await act?.();
    return done;
  }
  /// Waits until the transcript and the stack hold still over 12 painted frames, and no finite
  /// animation runs.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve) => {
          let last = "";
          let still = 0;
          let frames = 0;
          window.cmuxAfterPaint(() => {
            frames++;
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const rows = document.querySelectorAll<HTMLElement>(".acpmux-thread .acpmux-row");
            const dock = document.querySelector<HTMLElement>(".acpmux-main > .acpmux-dock")!;
            const now = [
              scroller.scrollTop,
              scroller.scrollHeight,
              dock.getBoundingClientRect().top,
              rows[rows.length - 1].getBoundingClientRect().bottom,
            ].join(",");
            const running = document
              .getAnimations()
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getComputedTiming().endTime !== Infinity,
              );
            still = now === last && !running ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 600) return true;
            resolve();
            return false;
          });
        }),
    );
  const placement = async (page: Page) => (await paintedFor(page, 0))[0];
  /// The wheel over the transcript's rows above the stack, in steps of 40 px as a trackpad sends.
  async function wheel(page: Page, total: number) {
    await page.mouse.move(450, 120);
    for (let moved = 0; moved < Math.abs(total); moved += 40) await page.mouse.wheel(0, Math.sign(total) * 40);
  }
  const fold = (page: Page) => page.locator(".acpmux-queue-fold").click();
  const expanded = (page: Page) => page.locator(".acpmux-queue-fold").getAttribute("aria-expanded");
  const prompt = (page: Page) =>
    page.locator(".acpmux-composer-box [contenteditable=true], .acpmux-composer-box textarea").first();

  /// Opens the chat at its latest row and notes where the last row rests over the stack there.
  async function open(name: string) {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await page.locator(".acpmux-queue-fold").waitFor({ timeout: 120_000 });
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 120_000 });
    await settle(page);
    const rest = await placement(page);
    expect({ rest: rest.fromEnd <= 1 && rest.gap >= 0 }).toEqual({ rest: true });
    return { page, rest: rest.gap };
  }

  /// Every frame in `frames` shows the last row whole, where the latest row rests over the stack.
  function expectAtRest(name: string, frames: Placement[], rest: number) {
    expect(frames.length).toBeGreaterThan(5);
    const off = frames.filter((frame) => frame.fromEnd > 1.5 || Math.abs(frame.gap - rest) > 2);
    expect({ name, off: off.slice(0, 4).map((frame) => ({ fromEnd: frame.fromEnd, gap: frame.gap })), rest }).toEqual({
      name,
      off: [],
      rest,
    });
  }

  for (const [name] of engines) {
    describe(name, () => {
      test("the queue opened, the view scrolled to its end shows the last row whole, and it stays", async () => {
        const { page, rest } = await open(name);
        await wheel(page, -1200);
        await settle(page);
        expect((await placement(page)).fromEnd).toBeGreaterThan(600);
        await fold(page);
        expect(await expanded(page)).toBe("true");
        await settle(page);
        await wheel(page, 2400);
        await settle(page);
        // Whole above the stack, and still there 500 ms later.
        expectAtRest(`${name}: opened, scrolled down`, await paintedFor(page, 500), rest);
        // Opened at the latest row too.
        await fold(page);
        await settle(page);
        await fold(page);
        await settle(page);
        expectAtRest(`${name}: opened at the latest row`, await paintedFor(page, 500), rest);
        await page.close();
      });

      test("the queue closed at the latest row keeps the last row on the stack, with no room that glides away", async () => {
        const { page, rest } = await open(name);
        await fold(page);
        await settle(page);
        expectAtRest(`${name}: opened`, await paintedFor(page, 200), rest);
        // From the frame after the click on, through FLOOR_HOLD_MS and past it: the last row never
        // floats a card's height above the stack, and never glides down to it later.
        const frames = await paintedFor(page, 1500, () => fold(page));
        expect(await expanded(page)).toBe("false");
        expectAtRest(`${name}: closed`, frames.slice(2), rest);
        await page.close();
      });

      test("a new line in the composer leaves the transcript's distance from its end as it was", async () => {
        const { page, rest } = await open(name);
        await prompt(page).click();
        await page.keyboard.type("Check the parser");
        await settle(page);
        for (let line = 0; line < 3; line++) {
          const frames = await paintedFor(page, 300, () => page.keyboard.press("Shift+Enter"));
          expectAtRest(`${name}: new line ${line + 1} at the latest row`, frames, rest);
        }
        // Scrolled up: the offset and the distance from the end hold still.
        await wheel(page, -600);
        await settle(page);
        const before = await placement(page);
        expect(before.fromEnd).toBeGreaterThan(300);
        await prompt(page).click();
        for (let line = 0; line < 3; line++) {
          const frames = await paintedFor(page, 300, () => page.keyboard.press("Shift+Enter"));
          const moved = frames.filter(
            (frame) => Math.abs(frame.fromEnd - before.fromEnd) > 1 || Math.abs(frame.top - before.top) > 1,
          );
          expect({ name, line, moved: moved.slice(0, 3) }).toEqual({ name, line, moved: [] });
        }
        await page.close();
      });

      test("the wheel beside the composer, left and right of the queue, its fold and the card, scrolls the transcript", async () => {
        const { page } = await open(name);
        await wheel(page, -1200);
        await settle(page);
        for (const part of [".acpmux-composer-queue", ".acpmux-queue-foldbar", ".acpmux-composer-box"]) {
          const box = (await page.locator(`.acpmux-main > .acpmux-dock > .acpmux-composer > ${part}`).boundingBox())!;
          const y = box.y + box.height / 2;
          for (const x of [box.x - 8, box.x + box.width + 8]) {
            const reaches = await page.evaluate(
              ([x, y]) => Boolean(document.elementFromPoint(x, y)?.closest(".acpmux-scroll")),
              [x, y] as const,
            );
            expect({ part, x, reaches }).toEqual({ part, x, reaches: true });
            for (const delta of [-300, 300]) {
              const before = (await placement(page)).top;
              await page.mouse.move(x, y);
              await page.mouse.wheel(0, delta);
              await settle(page);
              const moved = (await placement(page)).top - before;
              expect({
                part,
                x,
                delta,
                scrolls: Math.sign(moved) === Math.sign(delta) && Math.abs(moved) > 100,
              }).toEqual({ part, x, delta, scrolls: true });
            }
          }
        }
        await page.close();
      });
    });
  }
});
