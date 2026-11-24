// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, answers and commands, not shipped UI.
// Leo, 2026-11-07: "It accumulates empty space at the bottom, and when I scroll down, there, like,
// is eventually a swath of empty space", then "there's some tool calls that I open and close, and
// then the closed ones ... didn't, like, didn't have the wherewithal to, like, remove the space at
// the bottom of the app when it was, like, safe to do so."
//
// With "scroll to bottom on send" off, the reader sends, opens tool calls near the end, scrolls a
// little up and closes them, over several sends. A close a little above the end kept the content
// as tall as the view's end (VirtualTranscript `foldRoom`), so blank room stayed under the last row
// and nothing gave it back. At the end, after every cycle, the content must end at the last row
// plus the normal room for the composer, as it did before the first cycle.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fold-room-end.browser.test.ts", async () => {
  setDefaultTimeout(240_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-room-end: skipping (run `bunx playwright install chromium`)");
    describe.skip("fold room at the end", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/send-scroll-setting.html");
    for (const name of Object.keys(engines) as (keyof typeof engines)[])
      browsers[name] = await engines[name].launch({ headless: true });
  });
  afterAll(async () => {
    for (const each of Object.values(browsers)) await each?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = Date.now() - 3_600_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const call = (id: string, command: string, lines: number) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: command,
      kind: "execute",
      status: "completed",
      command,
      output: Array.from({ length: lines }, (_, index) => `line ${index + 1}: ok`).join("\n"),
    },
  });
  /// One finished turn: the prompt, a run of three commands with output, and a short reply.
  const turn = (id: string) => [
    row(`${id}-user`, "user", `Run the checks for ${id}`),
    row(`${id}-run`, "activity", undefined, {
      items: [
        call(`${id}-a`, `bun test ${id}`, 10),
        call(`${id}-b`, `bun run lint ${id}`, 10),
        call(`${id}-c`, "git status", 10),
      ],
    }),
    row(`${id}-reply`, "assistant", `The checks for ${id} pass.`),
  ];

  const frames = (page: Page, count: number) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);
  /// Waits until three painted frames in a row draw the scroller the same and nothing animates.
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
            // The follow chase (followChase.ts) draws the thread back with an inline `translate` on
            // the display's frames, not a Web Animation: while it is set, the rows are still moving.
            const moving =
              scroller
                .getAnimations({ subtree: true })
                .some((each) => each.playState === "running" && each.effect?.getTiming().iterations !== Infinity) ||
              [...scroller.querySelectorAll<HTMLElement>("[style]")].some((each) => each.style.translate !== "");
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error("the view did not come to rest in 10 s"));
              return false;
            }
          });
        }),
    );
  /// The room under the last row: the content's end less the last row's foot, in content pixels.
  const end = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const box = scroller.getBoundingClientRect();
      const foot = Math.max(
        ...[...scroller.querySelectorAll<HTMLElement>("article.acpmux-row")].map(
          (each) => each.getBoundingClientRect().bottom,
        ),
      );
      return {
        room: scroller.scrollHeight - (foot - box.top + scroller.scrollTop),
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
      };
    });
  /// The reader's wheel over the transcript.
  const wheel = async (page: Page, deltaY: number, steps = 1) => {
    const box = await page.locator(".acpmux-scroll").boundingBox();
    await page.mouse.move(box!.x + box!.width / 2, box!.y + 120);
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, deltaY);
      await frames(page, 2);
    }
    await settle(page);
  };
  /// The reader's wheel down until the view is at the content's end.
  const toEnd = async (page: Page) => {
    for (let step = 0; step < 30 && (await end(page)).fromEnd > 0.5; step += 1) await wheel(page, 600);
  };
  /// Clicks the disclosure `selector` finds where it is drawn, as the reader does.
  const click = async (page: Page, selector: string) => {
    const box = await page.locator(selector).first().boundingBox();
    if (!box) throw new Error(`nothing drawn for ${selector}`);
    await page.mouse.click(box.x + Math.min(24, box.width / 2), box.y + box.height / 2);
    await settle(page);
  };
  const expanded = (page: Page, selector: string) =>
    page
      .locator(selector)
      .first()
      .getAttribute("aria-expanded")
      .then((value) => value === "true");

  const open = async (name: keyof typeof engines) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browsers[name]!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/send-scroll-setting.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(() => {
      const harness = window as unknown as {
        __setScrollToBottomOnSend(on: boolean): void;
        __dock(queued: boolean): void;
      };
      harness.__setScrollToBottomOnSend(false);
      harness.__dock(false);
    });
    return page;
  };
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((next) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(next), rows);
  const sendWith = (page: Page, rows: Row[]) =>
    page.evaluate((next) => (window as unknown as { __sendWith(rows: unknown): void }).__sendWith(next), rows);

  for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
    test(`${name}: sends with tool calls opened and closed near the end leave no room under the last row`, async () => {
      const page = await open(name);
      let rows = Array.from({ length: 6 }, (_, index) => turn(`h${index}`)).flat();
      await show(page, rows);
      await settle(page);
      await toEnd(page);
      const base = (await end(page)).room;
      const failures: string[] = [];
      for (let cycle = 0; cycle < 6; cycle += 1) {
        const id = `s${cycle}`;
        // The reader sends from the latest row; the reply comes with its commands.
        rows = [...rows, row(`${id}-user`, "user", `Run the checks for ${id}`)];
        await sendWith(page, rows);
        await frames(page, 4);
        rows = [...rows, ...turn(id).slice(1)];
        await show(page, rows);
        await settle(page);
        await toEnd(page);
        // Opens the run of commands and its first command's output near the end (they grow down).
        const run = `[data-row-id="${id}-run"] button.is-run[aria-expanded]`;
        if (!(await expanded(page, run))) await click(page, run);
        const output = `[data-row-id="${id}-run"] button.cv-command[aria-expanded]`;
        if (!(await expanded(page, output))) await click(page, output);
        // Back at the end, a little up (less than what will close), and closes the run.
        await toEnd(page);
        await wheel(page, -60);
        if (!(await expanded(page, run))) failures.push(`cycle ${cycle}: the run is not open`);
        // Every painted frame of the close: the clicked line's top, and how far the close takes in.
        const closing = await page
          .locator(`[data-row-id="${id}-run"]`)
          .first()
          .evaluate((node) => node.getBoundingClientRect().height);
        const watching = page.evaluate(
          (query) =>
            new Promise<number[]>((resolve) => {
              const tops: number[] = [];
              const start = performance.now();
              window.cmuxAfterPaint(() => {
                const line = document.querySelector<HTMLElement>(query);
                if (line) tops.push(line.getBoundingClientRect().top);
                if (performance.now() - start < 700) return;
                resolve(tops);
                return false;
              });
            }),
          run,
        );
        // How far over the end the view sits as the close starts: the wheel's 60px, or a few px less
        // where WebKit's wheel lands short of it.
        const over = (await end(page)).fromEnd;
        await click(page, run);
        const tops = await watching;
        await settle(page);
        const closed =
          closing -
          (await page
            .locator(`[data-row-id="${id}-run"]`)
            .first()
            .evaluate((node) => node.getBoundingClientRect().height));
        // The line never moves up, and comes down no further than the close would have left blank:
        // what closed less what the view sat over the end.
        for (let index = 1; index < tops.length; index += 1)
          if (tops[index]! < tops[index - 1]! - 0.5)
            failures.push(
              `cycle ${cycle}: the clicked line moved up ${(tops[index - 1]! - tops[index]!).toFixed(1)}px`,
            );
        const travel = tops.at(-1)! - tops[0]!;
        if (travel > closed - over + 2)
          failures.push(
            `cycle ${cycle}: the clicked line came down ${travel.toFixed(1)}px for a ${closed.toFixed(1)}px close`,
          );
        await toEnd(page);
        const now = await end(page);
        if (Math.abs(now.room - base) > 1)
          failures.push(
            `cycle ${cycle}: ${now.room.toFixed(1)}px under the last row at the end, not ${base.toFixed(1)}px`,
          );
      }
      // CMUX_FOLD_ROOM_CAPTURE_DIR keeps the transcript's end after the cycles (the PR's before/after).
      const capture = process.env.CMUX_FOLD_ROOM_CAPTURE_DIR;
      if (capture) await page.screenshot({ path: path.join(capture, `fold-room-end-${name}.png`) });
      // Scrolled up and back down by hand: still nothing empty below the last row.
      await wheel(page, -400, 3);
      await toEnd(page);
      const last = await end(page);
      if (Math.abs(last.room - base) > 1)
        failures.push(`after scrolling: ${last.room.toFixed(1)}px under the last row, not ${base.toFixed(1)}px`);
      expect(failures).toEqual([]);
      await page.close();
    });
  }
});
