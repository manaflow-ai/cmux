// l10n-allow-file: test fixture prompts, replies and commands, not shipped UI.
// A chat's cold open builds the rows it shows first (CMUX-571, goal chat-attach-p95: the time from a
// chat's attach to its newest message painted was about six times the page's DOMContentLoaded).
//
// A 40-turn chat lands in an empty transcript, followed at its latest row, as an attach's page does.
// Before: the commit that took the rows drew them at offset 0, so it built the chat's top rows (the
// view, its scroll lead and the warm rows), and the placement pass that scrolled to the latest row
// unmounted them again before the frame; the same commit also built four viewports of history above
// the latest row. The open's first commit now builds the rows in view at the latest row, nothing it
// takes back, and the history comes in the render right after it: three screens of rows are mounted
// above the view within a few frames (Leo, 2026-11-12: "if you try to scroll up, you can't really
// scroll much of anything up at all"), and no row on screen moves once painted.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-open-view-first-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-open-view-first-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("a cold open builds the rows in view first", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  // A 40-turn chat of prompts, commands and replies of mixed length, the same every run.
  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let seed = 11;
  const rand = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));
  const words = "the batch script reads each file and writes a summary of what changed in the tree so far".split(" ");
  const sentence = (n: number) => Array.from({ length: n }, () => words[pick(0, words.length - 1)]).join(" ");
  const reply = (n: number) => Array.from({ length: n }, () => sentence(pick(8, 30))).join("\n\n");
  let at = Date.now() - 41 * 120_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const chat: Row[] = [];
  for (let t = 1; t <= 40; t += 1) {
    chat.push(row(`u${t}`, "user", sentence(pick(4, 16))));
    chat.push(
      row(`a${t}`, "activity", undefined, {
        items: Array.from({ length: pick(1, 3) }, (_, i) => ({
          kind: "tool",
          text: "",
          tool: {
            id: `c${t}_${i}`,
            title: `cat /tmp/f${t}_${i}`,
            kind: "execute",
            status: "completed",
            command: `cat /tmp/f${t}_${i}`,
            output: Array.from({ length: pick(2, 8) }, (_, l) => `line ${l + 1}: ok`).join("\n"),
          },
        })),
      }),
    );
    chat.push(row(`n${t}`, "assistant", reply(pick(1, 4))));
    chat.push(
      row(`s${t}`, "turnSummary", undefined, { status: "completed", durationMs: pick(4, 90) * 1000, toolCount: 2 }),
    );
    at += 60_000;
  }

  type Seen = {
    /// Rows the open mounted, in the DOM batch that first held rows (one commit and its placement).
    firstAdded: string[];
    /// Rows taken out of the DOM before the first frame that painted rows.
    removedBeforePaint: string[];
    /// Each painted frame from the first with rows: the rows on screen with their tops, and the
    /// height of mounted rows above the view, in screens.
    frames: { visible: [string, number][]; screensAbove: number }[];
  };
  const record = (page: Page) =>
    page.evaluate(() => {
      const seen: Seen = { firstAdded: [], removedBeforePaint: [], frames: [] };
      const rowsOf = (nodes: NodeList) =>
        [...nodes].flatMap((node) =>
          node instanceof HTMLElement
            ? [
                ...(node.matches("article.acpmux-row") ? [node] : []),
                ...node.querySelectorAll("article.acpmux-row"),
              ].map((each) => (each as HTMLElement).dataset.rowId!)
            : [],
        );
      const observer = new MutationObserver((list) => {
        if (seen.frames.length > 0) return;
        const added = list.flatMap((change) => rowsOf(change.addedNodes));
        if (seen.firstAdded.length === 0) seen.firstAdded = added;
        seen.removedBeforePaint.push(...list.flatMap((change) => rowsOf(change.removedNodes)));
      });
      observer.observe(document.body, { subtree: true, childList: true });
      window.cmuxAfterPaint(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return;
        const view = scroller.getBoundingClientRect();
        const visible: [string, number][] = [];
        let above = 0;
        for (const node of scroller.querySelectorAll<HTMLElement>("article.acpmux-row")) {
          const box = node.getBoundingClientRect();
          if (box.height <= 0) continue;
          above += Math.max(0, Math.min(box.bottom, view.top) - box.top);
          if (box.bottom > view.top && box.top < view.bottom) visible.push([node.dataset.rowId!, box.top]);
        }
        if (visible.length === 0 && seen.frames.length === 0) return;
        seen.frames.push({ visible, screensAbove: above / scroller.clientHeight });
        if (seen.frames.length >= 30) {
          observer.disconnect();
          return false;
        }
      });
      (window as unknown as { __seen: Seen }).__seen = seen;
    });

  test("the open's first commit builds the rows in view at the latest row, then the history above", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLoadingRows" in window);
    await page.evaluate(() =>
      (window as unknown as { __showLoadingRows(rows: unknown, loading: boolean): void }).__showLoadingRows([], true),
    );
    await record(page);
    await page.evaluate(
      (rows) =>
        (window as unknown as { __showLoadingRows(rows: unknown, loading: boolean): void }).__showLoadingRows(
          rows,
          false,
        ),
      chat,
    );
    await page.waitForFunction(() => (window as unknown as { __seen: Seen }).__seen.frames.length >= 30, undefined, {
      timeout: 20_000,
    });
    const seen = await page.evaluate(() => (window as unknown as { __seen: Seen }).__seen);
    const first = seen.frames[0]!;
    // The first painted frame is the chat's latest row.
    expect(first.visible.map(([id]) => id)).toContain("s40");
    // Nothing the open built went before its first frame: no top rows drawn and unmounted.
    expect(seen.removedBeforePaint).toEqual([]);
    // Its first commit built the rows in view and the virtual list's few rows of overscan either side,
    // not the history above them.
    expect(seen.firstAdded.length).toBeLessThanOrEqual(first.visible.length + 10);
    // The history comes right after: three screens mounted above the view within ten frames.
    expect(seen.frames.slice(0, 10).some((frame) => frame.screensAbove >= 3)).toBe(true);
    // And no row on screen in the first frame moved after it.
    const tops = new Map(first.visible);
    const moved = seen.frames.flatMap((frame) =>
      frame.visible.filter(([id, top]) => tops.has(id) && Math.abs(tops.get(id)! - top) > 1).map(([id]) => id),
    );
    expect(moved).toEqual([]);
    await page.close();
  });
});
