// l10n-allow-file: test fixture prompts, answers and commands, not shipped UI.
// A disclosure clicked while the page is slow and a turn streams opens in place (Leo, 2026-11-10, on
// a recording of a chat at load ~260: "when things get slow this tool call expansion situatoin gets
// insanely f***ed"). The hold that keeps the clicked line where it was clicked (foldAnchor.ts) was
// timed from the click: a render that took longer than it found the hold over, so the pass that drew
// the opened body neither held the line nor stopped following the latest row, and the view jumped to
// the bottom with the clicked line and the group's header gone from it.
//
// The hold was timed from the click; the row's new height reached the transcript only after the
// browser laid out what opened, and under load that came later than the hold lasted. Here that layout
// is made slow on purpose (the page is busy for 1.2 s right after React drew the click, before the next
// frame) while the turn streams: its reply grows every 40 ms, each update busy for 8 ms more, and a new
// call joins the run part way ("Ran 4 commands").
// Every collapsible kind the run draws is clicked so: the run's own line and a command's line.
// - The clicked line opens and stays open through every streamed update.
// - It stays on the pixel it was clicked at, and the run's header with it: the view stops following.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-toggle-under-load-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-toggle-under-load-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("a toggle under load opens in place", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const name of Object.keys(engines) as (keyof typeof engines)[])
      browsers[name] = await engines[name].launch({ headless: true });
  });
  afterAll(async () => {
    for (const each of Object.values(browsers)) await each?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const sent = Date.now() - 180_000;
  let at = sent - 3_600_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const paragraphs = (count: number, word: string) =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The ${word} climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  const call = (id: string, command: string, lines = 14) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: command,
      kind: "execute",
      status: "completed",
      command,
      output: Array.from({ length: lines }, (_, index) => `${index + 1}a2b3c4 commit ${index + 1}`).join("\n"),
      startedAt: sent + 5_000,
    },
  });
  const done = Array.from({ length: 6 }, (_, index) => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", paragraphs(2, "keeper")),
  ]).flat();
  const calls = [
    call("b1", "cat /tmp/review/output.txt"),
    call("b2", "git log --oneline -14 -- Sources/Cloud"),
    call("b3", "router-review manaflow-ai/cmux 9062"),
  ];
  /// A running turn whose last activity is a run of three commands, with the reply under it.
  const live: Row[] = [
    ...done,
    { ...row("live-user", "user", "Find the recent Cloud commits and start the review."), at: sent },
    row("prose-a", "assistant", paragraphs(2, "pilot")),
    row("run-b", "activity", undefined, { items: calls }),
    row("prose-c", "assistant", "Reading the log now."),
  ];

  /// Resolves once nothing moves: no fold running, and three painted frames alike.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((resolve, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 15_000;
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
              .map((node) => `${node.dataset.rowId}@${Math.round(node.getBoundingClientRect().top)}`)
              .join(",");
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${rows}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              resolve();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 15 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  const toLatest = async (page: Page) => {
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
      node.scrollTop = node.scrollHeight;
      node.dispatchEvent(new Event("scroll"));
    });
    await settle(page);
  };
  const open = async (browser: Browser) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser.newPage({ viewport: { width: 900, height: 760 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLiveRows" in window);
    await page.evaluate(() => (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(false));
    await page.evaluate(
      (rows) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(rows),
      live,
    );
    await settle(page);
    await toLatest(page);
    return page;
  };

  type Watch = { line: number; header: number; expanded: boolean; inView: boolean; height: number };
  /// Marks the line `pick` names in the run (data-probe), makes the click on it slow, streams the
  /// reply, clicks it, and reads it at every painted frame until the stream ends.
  const slowClick = async (page: Page, pick: "run" | "command") => {
    const point = await page.evaluate((which) => {
      const run = document.querySelector<HTMLElement>('[data-row-id="run-b"]')!;
      const lines = [...run.querySelectorAll<HTMLElement>("[aria-expanded]")];
      // The run's own line is its first; a command's line is one shut under it.
      const line =
        which === "run"
          ? lines[0]
          : (run.querySelector<HTMLElement>('[data-tool-id="b2"][aria-expanded="false"]') ??
            lines.find((each, index) => index > 0 && each.getAttribute("aria-expanded") === "false"));
      if (!line) throw new Error(`no ${which} line in the run: ${run.innerHTML.slice(0, 400)}`);
      document.querySelector("[data-probe]")?.removeAttribute("data-probe");
      line.dataset.probe = "true";
      // The browser lays out what the click opened 1.2 s late: the page is busy right after React's
      // handler drew it (a window listener runs after the root's), before the next frame, as a
      // render at that load is. The row's new height reaches the transcript only then.
      window.addEventListener(
        "click",
        () => {
          const until = performance.now() + 1_200;
          while (performance.now() < until);
        },
        { once: true },
      );
      // Where the line and the run are when the reader presses: what the transcript holds.
      window.addEventListener(
        "pointerdown",
        () => {
          (window as unknown as { __pressed: { line: number; header: number } }).__pressed = {
            line: line.getBoundingClientRect().top,
            header: run.getBoundingClientRect().top,
          };
        },
        { capture: true, once: true },
      );
      const box = line.getBoundingClientRect();
      return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
    }, pick);
    // The turn streams: the reply grows every 40 ms (each update busy 8 ms more), and a fourth call
    // joins the run part way, so the run's lines are drawn anew around the clicked one.
    await page.evaluate(
      ({ rows, extra }) => {
        const w = window as unknown as {
          __showLiveRows(rows: unknown): void;
          __stream?: { stop(): void; ticks: number };
        };
        let tick = 0;
        let text = "Reading the log now.";
        const timer = setInterval(() => {
          tick += 1;
          text += ` Line ${tick} of the reply streams in while the page is slow.`;
          const next = rows.map((each) => {
            if (each.id === "prose-c") return { ...each, text, version: 1 + tick };
            if (each.id === "run-b" && tick >= 12)
              return { ...each, items: [...(each.items as unknown[]), extra], version: 2 };
            return each;
          });
          w.__showLiveRows(next);
          const until = performance.now() + 8;
          while (performance.now() < until);
        }, 40);
        w.__stream = {
          stop: () => clearInterval(timer),
          get ticks() {
            return tick;
          },
        };
      },
      { rows: live, extra: call("b4", "gh pr checks 9062", 4) },
    );
    const read = () =>
      page.evaluate((which): Watch => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const line =
          document.querySelector<HTMLElement>("[data-probe]") ??
          // A line the regroup drew anew: the same call's line, found by its id, or the run's line.
          document.querySelector<HTMLElement>(
            which === "command" ? '[data-row-id="run-b"] [data-tool-id="b2"]' : '[data-row-id="run-b"] [aria-expanded]',
          )!;
        const box = line.getBoundingClientRect();
        const header = document.querySelector<HTMLElement>('[data-row-id="run-b"]')!.getBoundingClientRect().top;
        return {
          line: box.top,
          header,
          expanded: line.getAttribute("aria-expanded") === "true",
          inView: box.top >= scroller.top - 0.5 && box.bottom <= scroller.bottom + 0.5,
          height: document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight,
        };
      }, pick);
    await page.mouse.click(point.x, point.y);
    const pressed = await page.evaluate(
      () => (window as unknown as { __pressed: { line: number; header: number } }).__pressed,
    );
    const height = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight);
    const before = { ...pressed, height };
    // The stream runs on for 1.5 s after the click's render.
    // fixed-wait: the test reads the view while the turn keeps streaming; the window is the test
    await page.waitForTimeout(1_500);
    const during = await read();
    await page.evaluate(() => (window as unknown as { __stream: { stop(): void } }).__stream.stop());
    await settle(page);
    const after = await read();
    return { before, during, after };
  };

  for (const name of Object.keys(engines) as (keyof typeof engines)[])
    for (const pick of ["command", "run"] as const)
      test(`${name}: a ${pick} line clicked during a slow render while the turn streams opens in place`, async () => {
        const page = await open(browsers[name]!);
        const failures: string[] = [];
        // The run is open while it runs: its line closes on the first click, so open the command
        // under it, and for the run's own line close it first, then open it slowly.
        if (pick === "run") {
          const shut = await page.evaluate(() => {
            const line = document.querySelector<HTMLElement>('[data-row-id="run-b"] [aria-expanded]')!;
            if (line.getAttribute("aria-expanded") === "true") line.click();
            return true;
          });
          if (shut) await settle(page);
          await toLatest(page);
        }
        if (!(await atLatest(page))) failures.push("the view does not start at the latest row");
        const { before, during, after } = await slowClick(page, pick);
        for (const [when, seen] of [
          ["during the stream", during],
          ["at rest", after],
        ] as const) {
          if (!seen.expanded) failures.push(`${when}: the clicked line is not open`);
          if (!seen.inView) failures.push(`${when}: the clicked line left the view`);
          const moved = seen.line - before.line;
          if (Math.abs(moved) > 2) failures.push(`${when}: the clicked line moved ${moved.toFixed(1)}px`);
          const header = seen.header - before.header;
          if (Math.abs(header) > 2) failures.push(`${when}: the run's header moved ${header.toFixed(1)}px`);
        }
        if (await atLatest(page)) failures.push("the view still follows the latest row");
        // The stream and the opened body grew the transcript, so a view that followed would have moved.
        if (!(after.height > before.height + 100)) failures.push("the transcript did not grow under the click");
        console.log(`${name} ${pick}: ${JSON.stringify({ before, during, after })}`);
        expect(failures).toEqual([]);
        await page.close();
      });
});
