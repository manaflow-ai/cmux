// cmux-web-test-timeout: 600
// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// A hidden chat lets go of its transcript's rows and draws them again, where they lay, in its first
// frame back (VirtualTranscript.tsx HIDDEN RELEASE). Goal sim-fidelity-flat-ladder (Leo: "the goal is
// infinity chats, infinity browser tabs, whatever."): each hidden chat page kept ~71 mounted rows
// (~4 MB of JS heap and ~3.7 MB of DOM and style) that nobody sees.
//
// The page hides as the app's hidden chat pages do (`visibilityState` "hidden", `visibilitychange`,
// no frame callbacks). Checked: hidden, the transcript mounts no row and marks its scroller; shown
// again, the first painted frame has the rows back with the same top row at the same offset and the
// same scroll position, for a reader scrolled up into the middle and one following the latest row.
// That no chat copy is written from the released transcript: chatSnapshot/live.test.ts.
// Locally: CMUX_BROWSER_TESTS=1 bun test test/agent-pane-hidden-release-anchor.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { PAPERCUT_CHAT, papercutEvents } from "./support/papercutChat";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-hidden-release-anchor.test.ts", async () => {
  setDefaultTimeout(600_000);
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  const { events, session } = papercutEvents({ turns: 40, running: false });
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

  let browser: Browser | undefined;
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
    await warmViteServer(vite, "/", { timeoutMs: 600_000, jobs: 4 });
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
    await daemon?.stop(true);
  });

  /// Hides as a covered chat page hides: `visibilityState` reads "hidden", `visibilitychange` fires,
  /// and frame callbacks wait for the page to show. Installed before the page's scripts.
  const installHide = (page: Page) =>
    page.addInitScript(() => {
      let hidden = false;
      const raf = window.requestAnimationFrame.bind(window);
      const caf = window.cancelAnimationFrame.bind(window);
      const waiting = new Map<number, FrameRequestCallback>();
      let ids = 1 << 29;
      window.requestAnimationFrame = (run) => {
        if (!hidden) return raf(run);
        ids += 1;
        waiting.set(ids, run);
        return ids;
      };
      window.cancelAnimationFrame = (id) => {
        if (!waiting.delete(id)) caf(id);
      };
      Object.defineProperty(document, "visibilityState", {
        configurable: true,
        get: () => (hidden ? "hidden" : "visible"),
      });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => hidden });
      (window as unknown as { chatnftHide: (next: boolean) => void }).chatnftHide = (next) => {
        hidden = next;
        document.dispatchEvent(new Event("visibilitychange"));
        if (!next) {
          const due = [...waiting.values()];
          waiting.clear();
          for (const run of due) raf(run);
        }
      };
    });
  const setHidden = (page: Page, hidden: boolean) =>
    page.evaluate(
      (hidden) => (window as unknown as { chatnftHide: (next: boolean) => void }).chatnftHide(hidden),
      hidden,
    );

  type Anchor = { count: number; released: boolean; scrollTop: number; top: string; offset: number };
  /// The transcript as drawn: its mounted rows, the first row whose bottom is below the scroller's
  /// top and that row's offset from it.
  const readAnchor = (): Anchor => {
    const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
    const rows = [...document.querySelectorAll<HTMLElement>(".acpmux-thread .acpmux-row[data-row-id]")];
    const box = scroller.getBoundingClientRect();
    const first = rows
      .map((row) => ({ row, rect: row.getBoundingClientRect() }))
      .filter(({ rect }) => rect.height > 0 && rect.bottom > box.top + 1)
      .sort((a, b) => a.rect.top - b.rect.top)[0];
    return {
      count: rows.length,
      released: scroller.hasAttribute("data-rows-released"),
      scrollTop: scroller.scrollTop,
      top: first?.row.dataset.rowId ?? "",
      offset: first ? first.rect.top - box.top : 0,
    };
  };
  /// The transcript in the first painted frame after `act`.
  const firstFrameAfter = async (page: Page, act: () => Promise<unknown>): Promise<Anchor> => {
    const frame = page.evaluate(
      () =>
        new Promise<Anchor>((resolve) => {
          const read = (window as unknown as { readAnchor: () => Anchor }).readAnchor;
          window.cmuxAfterPaint(() => {
            resolve(read());
            return false;
          });
        }),
    );
    await act();
    return frame;
  };
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
            const rows = document.querySelectorAll(".acpmux-thread .acpmux-row");
            const now = [scroller.scrollTop, scroller.scrollHeight, rows.length].join(",");
            still = now === last ? still + 1 : 0;
            last = now;
            if (still < 12 && frames < 600) return true;
            resolve();
            return false;
          });
        }),
    );

  async function open() {
    const page = await browser!.newPage({ viewport: { width: 980, height: 700 } });
    await installHide(page);
    await installPaintedFrames(page);
    await page.addInitScript(`window.readAnchor = ${readAnchor.toString()}`);
    const { port } = vite!.httpServer!.address() as { port: number };
    const endpoint = `ws://127.0.0.1:${daemon!.port}/`;
    await page.goto(
      `http://127.0.0.1:${port}/#endpoint=${encodeURIComponent(endpoint)}&token=t&session=${PAPERCUT_CHAT}`,
    );
    await page.getByText("Answer 40:", { exact: false }).waitFor({ timeout: 120_000 });
    await settle(page);
    return page;
  }
  const read = (page: Page) => page.evaluate(() => (window as unknown as { readAnchor: () => Anchor }).readAnchor());
  /// Waits one task past the hide, as the release does (it lets the hide's own handlers read the rows).
  const nextTask = (page: Page) => page.evaluate(() => new Promise((resolve) => setTimeout(resolve, 20)));

  const cases: { name: string; place: (page: Page) => Promise<unknown> }[] = [
    { name: "following the latest row", place: async () => {} },
    {
      name: "scrolled up into the middle",
      place: (page) =>
        page.evaluate(() => {
          const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          scroller.scrollTop = Math.round((scroller.scrollHeight - scroller.clientHeight) * 0.45) + 7;
        }),
    },
  ];

  describe("hidden transcript release", () => {
    for (const { name, place } of cases)
      test(`${name}: hidden, no rows; shown, the same rows at the same place in the first frame`, async () => {
        const page = await open();
        await place(page);
        await settle(page);
        const before = await read(page);
        expect(before.count).toBeGreaterThan(0);
        expect(before.released).toBe(false);
        expect(before.top).not.toBe("");

        await setHidden(page, true);
        await nextTask(page);
        const hidden = await read(page);
        expect({ count: hidden.count, released: hidden.released }).toEqual({ count: 0, released: true });
        // The scroll range and position stay: the rows' measured heights outlive the rows.
        expect(Math.abs(hidden.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);

        const shown = await firstFrameAfter(page, () => setHidden(page, false));
        expect(shown.released).toBe(false);
        expect(shown.count).toBeGreaterThan(0);
        expect({ top: shown.top }).toEqual({ top: before.top });
        expect(Math.abs(shown.offset - before.offset)).toBeLessThanOrEqual(1);
        expect(Math.abs(shown.scrollTop - before.scrollTop)).toBeLessThanOrEqual(1);
        await page.close();
      });
  });
});
