// l10n-allow-file: test fixture prompts, replies, commands and tool titles, not shipped UI.
// Older history landing above the reader on open keeps the rows on screen mounted, and no frame
// goes blank (Leo, 2026-11-11: "they just appear and disappear, and then they constantly load and
// reload").
//
// A chat opens on its latest page: the last 24 rows of a 40-turn chat, followed at the bottom, while
// its read is still loading. The read lands with the whole chat, the older turns above. The rows on
// screen must stay the same nodes, and every painted frame must show some of them.
//
// Before: the commit that took the whole chat placed its rows at the old offset, in a layout 16
// turns taller above it. That offset falls in the third turn, so the rows on screen unmounted, the
// third turn's rows mounted off screen, one frame painted no row, and the rows on screen came back
// as new nodes over the next frames (a flip probe in Chromium: 12 message rows and 6 tool rows
// remounted per open).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-open-history-no-remount-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-open-history-no-remount-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("older history on open keeps the rows on screen", () => test("chromium", () => {}));
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
  let seed = 7;
  const rand = () => (seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff;
  const pick = (lo: number, hi: number) => lo + Math.floor(rand() * (hi - lo + 1));
  const words = "the batch script reads each file and writes a summary of what changed in the tree so far".split(" ");
  const sentence = (n: number) => Array.from({ length: n }, () => words[pick(0, words.length - 1)]).join(" ");
  const replyLines = (n: number) => {
    const lines: string[] = [];
    while (lines.length < n) {
      const k = pick(0, 4);
      if (k === 0) lines.push(`## ${sentence(3)}`, "");
      else if (k === 1) lines.push(`- ${sentence(pick(4, 14))}`, `- ${sentence(pick(4, 14))}`);
      else if (k === 2) lines.push("```ts", `const x = ${pick(1, 99)};`, "return x;", "```", "");
      else lines.push(sentence(pick(8, 40)), "");
    }
    return lines.slice(0, n);
  };
  const command = (id: string, line: string, out: number) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: line,
      kind: "execute",
      status: "completed",
      command: line,
      output: Array.from({ length: out }, (_, i) => `line ${i + 1}: ok`).join("\n"),
    },
  });
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
    chat.push(row(`u${t}`, "user", replyLines(pick(1, 3)).filter(Boolean).join("\n") || sentence(6)));
    chat.push(
      row(`a${t}`, "activity", undefined, {
        items: Array.from({ length: pick(2, 4) }, (_, i) => command(`c${t}_${i}`, `cat /tmp/f${t}_${i}`, pick(3, 15))),
      }),
    );
    chat.push(row(`n${t}`, "assistant", replyLines(pick(5, 40)).join("\n")));
    chat.push(
      row(`s${t}`, "turnSummary", undefined, { status: "completed", durationMs: pick(4, 90) * 1000, toolCount: 3 }),
    );
    at += 60_000;
  }

  const show = (page: Page, rows: Row[], loading: boolean) =>
    page.evaluate(
      ({ rows, loading }) =>
        (window as unknown as { __showLoadingRows(rows: unknown, loading: boolean): void }).__showLoadingRows(
          rows,
          loading,
        ),
      { rows, loading },
    );
  /// Resolves once three painted frames in a row show the transcript as the frame before, with no
  /// fold or glide running.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 10_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            const moving = scroller
              .getAnimations({ subtree: true })
              .some(
                (animation) =>
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const rows = [...scroller.querySelectorAll<HTMLElement>("article.acpmux-row")]
              .map((node) => `${node.dataset.rowId}@${node.style.top}+${node.style.marginTop}`)
              .join(",");
            const now = `${scroller.scrollHeight} ${scroller.scrollTop} ${rows}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the transcript did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  /// In the page: the rows on screen now, then a recorder of every row element taken out of the DOM
  /// and of each painted frame's rows on screen, until `stop` returns what it saw.
  const record = (page: Page) =>
    page.evaluate(() => {
      const onScreen = () => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        if (!scroller) return [];
        const view = scroller.getBoundingClientRect();
        return [...scroller.querySelectorAll<HTMLElement>("article.acpmux-row")].flatMap((node) => {
          const box = node.getBoundingClientRect();
          return box.height > 0 && box.bottom > view.top && box.top < view.bottom ? [node.dataset.rowId!] : [];
        });
      };
      const before = onScreen();
      const removed: string[] = [];
      const observer = new MutationObserver((list) => {
        for (const change of list)
          for (const gone of change.removedNodes) {
            if (!(gone instanceof HTMLElement)) continue;
            const rows = gone.matches("article.acpmux-row") ? [gone] : gone.querySelectorAll("article.acpmux-row");
            for (const each of rows) removed.push((each as HTMLElement).dataset.rowId!);
          }
      });
      observer.observe(document.querySelector(".acpmux-scroll")!, { subtree: true, childList: true });
      const frames: string[][] = [];
      const stopFrames = window.cmuxAfterPaint(() => void frames.push(onScreen()));
      (window as unknown as { __stopRecord(): unknown }).__stopRecord = () => {
        stopFrames();
        observer.disconnect();
        return { before, removed, frames };
      };
      return before;
    });
  const stop = (page: Page) =>
    page.evaluate(() =>
      (
        window as unknown as { __stopRecord(): { before: string[]; removed: string[]; frames: string[][] } }
      ).__stopRecord(),
    );

  test("older history landing above the followed bottom keeps the rows on screen mounted, with no blank frame", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLoadingRows" in window);

    // The open's first page: the latest six turns, followed at the bottom, the read still loading.
    await show(page, [], true);
    await show(page, chat.slice(-24), true);
    await settle(page);
    const before = await record(page);
    expect(before).toContain("s40");

    // The read lands: the whole chat, its older turns above the rows on screen.
    await show(page, chat, false);
    await settle(page);
    const seen = await stop(page);

    // No row that was on screen left the DOM, and every painted frame showed rows.
    expect(seen.frames.length).toBeGreaterThan(0);
    expect({
      remounted: seen.removed.filter((id) => before.includes(id)),
      blankFrames: seen.frames.flatMap((rows, frame) => (rows.length === 0 ? [frame] : [])),
    }).toEqual({ remounted: [], blankFrames: [] });
    // And the view still rests on the latest row.
    expect(seen.frames.at(-1)).toContain("s40");
    await page.close();
  });
});
