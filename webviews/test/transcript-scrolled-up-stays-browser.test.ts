// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A reader who scrolled up is never snapped back to the latest row (Leo, 2026-11-17: rows "shifting
// every time I'm scrolling" while a turn ran). A running turn streams its reply and adds steps to its
// run; the reader, at the latest row, wheels up three notches, wheels on up until a box with its own
// scroll is in view (an opened run's 224 px box, a command's output, an edit's diff), wheels inside
// that box, then rests three seconds. All of it is real input (Playwright's mouse). From the first
// notch up the view no longer follows the latest row (`followTrace`), and from the moment the box is
// in view nothing the reader did not scroll moves: the transcript's offset, and every row in view, at
// every painted frame, while the stream goes on.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { pinLiveTurnRuns } from "./support/liveTurnRuns";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-scrolled-up-stays-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(
        `transcript-scrolled-up-stays-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`,
      );
    }
  }
  if (engines.length === 0) {
    describe.skip("a reader who scrolled up stays", () => test("no engine", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  const browsers = new Map<string, Browser>();
  beforeAll(async () => {
    vite = await createServer({
      root: webviews,
      configFile: path.join(webviews, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    for (const [name, type] of engines) browsers.set(name, await type.launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
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
    text: command,
    tool: {
      id,
      title: command,
      kind: "execute",
      status: "completed",
      command,
      output: Array.from({ length: lines }, (_, index) => `${index + 1}a2b3c4 commit ${index + 1}`).join("\n"),
      exitCode: 0,
    },
  });
  const source = (count: number, value: number) =>
    Array.from({ length: count }, (_, index) => `export const value${index} = ${value + index};`).join("\n") + "\n";
  const edit = {
    kind: "tool",
    text: "Edit src/retry.ts",
    tool: {
      id: "edit-1",
      title: "Edit src/retry.ts",
      kind: "edit",
      status: "completed",
      locations: [{ path: "/home/dev/cmux/src/retry.ts" }],
      diffs: [{ path: "/home/dev/cmux/src/retry.ts", oldText: source(60, 1), newText: source(60, 2) }],
    },
  };
  const done = Array.from({ length: 4 }, (_, index) => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", paragraphs(2, "keeper")),
  ]).flat();
  /// A finished turn with a command whose output runs past its box and an edit with a long diff.
  const worked = [
    row("w-user", "user", "Run the retry tests and fix the guard."),
    row("w-cmd", "activity", undefined, { settled: true, items: [call("w-cmd", "bun test src/retry", 40)] }),
    row("w-edit", "activity", undefined, {
      settled: true,
      foldRun: true,
      items: [edit, ...Array.from({ length: 15 }, (_, n) => call(`w-check-${n}`, `bun run lint src/part${n}`, 2))],
    }),
    row("w-answer", "assistant", paragraphs(1, "pilot")),
  ];
  const steps = (count: number) =>
    Array.from({ length: count }, (_, index) => call(`b${index}`, `git log --oneline -14 -- Sources/Cloud${index}`));
  /// The running turn: its prompt, prose, a run of commands that grows, and the reply streaming under it.
  const live: Row[] = [
    ...done,
    ...worked,
    { ...row("live-user", "user", "Find the recent Cloud commits and start the review."), at: sent },
    row("prose-a", "assistant", paragraphs(2, "pilot")),
    row("run-b", "activity", undefined, { items: steps(30) }),
    row("prose-c", "assistant", "Reading the log now."),
  ];

  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  const show = (page: Page) =>
    page.evaluate((rows) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(rows), live);
  const following = (page: Page) =>
    page.evaluate(
      () => (window as unknown as { __followSnapshot(): { following: boolean } }).__followSnapshot().following,
    );
  const scroller = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const box = node.getBoundingClientRect();
      return { top: box.top, bottom: box.bottom, left: box.left, scrollTop: node.scrollTop };
    });
  /// The box with its own vertical scroll in `rowId` (`selector`, in the row or in a shadow root in
  /// it: a diff draws in one), in the viewport's coordinates.
  const nested = (page: Page, rowId: string, selector: string) =>
    page.evaluate(
      ([id, pick]) => {
        const holder = document.querySelector<HTMLElement>(`.acpmux-scroll .acpmux-row[data-row-id="${id}"]`);
        const roots: ParentNode[] = holder ? [holder] : [];
        for (const each of holder?.querySelectorAll<HTMLElement>("*") ?? [])
          if (each.shadowRoot) roots.push(each.shadowRoot);
        const node = roots
          .flatMap((root) => [...root.querySelectorAll<HTMLElement>(pick)])
          .find((each) => each.scrollHeight > each.clientHeight + 1);
        if (!node) return null;
        const box = node.getBoundingClientRect();
        return { top: box.top, bottom: box.bottom, left: box.left, scrollTop: node.scrollTop };
      },
      [rowId, selector] as const,
    );

  /// Where each reader-opened box is: its row, the line that opens it, and the element that scrolls.
  const BOXES = {
    "run box": { rowId: "run-b", opener: "button[data-tool-group]", scrolls: ".cv-run-scroll" },
    "command output": { rowId: "w-cmd", opener: '[aria-expanded="false"]', scrolls: ".cv-shell__body" },
    // The run's line, then its edit's line: the diff's lines scroll in their own box (its shadow root's
    // `code`), in the run's box.
    diff: { rowId: "w-edit", opener: '[aria-expanded="false"]', scrolls: "code" },
  } as const;

  for (const [name] of engines)
    for (const [kind, spec] of Object.entries(BOXES))
      test(`${name}: a reader who scrolled up to a ${kind} while the turn streams is not moved`, async () => {
        const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 760 } });
        await installPaintedFrames(page);
        // A running turn draws its finished runs as lines the reader opens (live-turn-work's `runs`).
        await pinLiveTurnRuns(page);
        const { port } = vite!.httpServer!.address() as { port: number };
        await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
        await page.waitForFunction(() => "__showLiveRows" in window);
        await show(page);
        await painted(page, 10);
        // The reader opens the box's line (the diff: the command's, then the edit's), then goes back
        // to the latest row with the wheel.
        const view = await scroller(page);
        const openers = page.locator(`.acpmux-row[data-row-id="${spec.rowId}"] ${spec.opener}`);
        for (let pass = 0; pass < (kind === "diff" ? 2 : 1); pass++) {
          const line = openers.first();
          // The reader wheels up to it: the line wholly in view, clear of the view's foot.
          for (let notch = 0; notch < 80; notch++) {
            const at = await line.boundingBox();
            if (at && at.y >= view.top && at.y + at.height <= view.bottom - 80) break;
            await page.mouse.move(view.left + 40, view.top + 40);
            await page.mouse.wheel(0, at && at.y < view.top ? -100 : at ? 100 : -400);
            await painted(page, 3);
          }
          await line.click();
          await painted(page, 20);
        }
        await page.mouse.move(view.left + 40, view.top + 40);
        for (let notch = 0; notch < 60 && !(await following(page)); notch++) {
          await page.mouse.wheel(0, 400);
          await painted(page, 3);
        }
        expect({ followingAtStart: await following(page) }).toEqual({ followingAtStart: true });

        // The turn streams: the reply grows every 50 ms, and a step joins the run every 8th time.
        await page.evaluate(
          ({ rows, step }) => {
            const w = window as unknown as { __showLiveRows(rows: unknown): void; __stream?: { stop(): void } };
            type Shown = { id: string; version: number; text?: string; items?: unknown[] };
            let tick = 0;
            const timer = setInterval(() => {
              tick += 1;
              const next = (rows as Shown[]).map((each) => {
                if (each.id === "prose-c")
                  return {
                    ...each,
                    text: `${each.text}${" The next line of the reply streams in.".repeat(tick)}`,
                    version: 1 + tick,
                  };
                if (each.id === "run-b") {
                  const added = Array.from({ length: Math.floor(tick / 8) }, (_, n) => {
                    const one = structuredClone(step) as { tool: { id: string } };
                    one.tool.id = `added-${n}`;
                    return one;
                  });
                  return { ...each, items: [...each.items!, ...added], version: 1 + tick };
                }
                return each;
              });
              w.__showLiveRows(next);
            }, 50);
            w.__stream = { stop: () => clearInterval(timer) };
          },
          { rows: live, step: call("added", "gh pr checks 9062", 4) },
        );

        const failures: string[] = [];
        // Three notches up over the transcript, away from any box: it lets go of the latest row.
        for (let notch = 1; notch <= 3; notch++) {
          await page.mouse.wheel(0, -100);
          await painted(page, 3);
          if (await following(page)) failures.push(`still following after notch ${notch} up`);
        }
        // On up until the box is wholly in view (the reader's own scroll).
        let box = await nested(page, spec.rowId, spec.scrolls);
        for (let notch = 0; notch < 80 && !(box && box.top >= view.top && box.bottom <= view.bottom - 40); notch++) {
          await page.mouse.wheel(0, box && box.top > view.top ? 60 : -100);
          await painted(page, 3);
          box = await nested(page, spec.rowId, spec.scrolls);
        }
        if (!box) {
          failures.push(`no ${kind} with its own scroll in ${spec.rowId}`);
          await page.evaluate(() => (window as unknown as { __stream: { stop(): void } }).__stream.stop());
          await page.close();
          expect(failures).toEqual([]);
          return;
        }
        // The reader's own scroll comes to rest: the transcript's offset stays within 0.5 px of one
        // value for 10 painted frames and 300 ms (a wheel's eased distance, the transcript's or WebKit's,
        // runs on the clock: at a fast frame rate its tail moves under 0.5 px a frame for many frames).
        await page.evaluate(async () => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          let since = { top: node.scrollTop, at: performance.now(), frames: 0 };
          for (let frames = 0; frames < 2_000; frames++) {
            await window.cmuxPaintFrame();
            if (Math.abs(node.scrollTop - since.top) >= 0.5)
              since = { top: node.scrollTop, at: performance.now(), frames: 0 };
            else since.frames += 1;
            if (since.frames >= 10 && performance.now() - since.at >= 300) return;
          }
        });
        box = (await nested(page, spec.rowId, spec.scrolls))!;

        // From here the reader scrolls only the box: watch the transcript's offset and its rows.
        await page.evaluate((transcriptRow) => {
          const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
          const places = () => {
            const view = node.getBoundingClientRect();
            const tops = new Map<string, number>();
            for (const each of node.querySelectorAll<HTMLElement>(transcriptRow)) {
              const rect = each.getBoundingClientRect();
              if (rect.bottom <= view.top + 1 || rect.top >= view.bottom - 1) continue;
              tops.set(each.dataset.rowId!, rect.top);
            }
            return tops;
          };
          const watch = {
            moves: [] as string[],
            offsets: [] as string[],
            following: 0,
            frames: 0,
            started: performance.now(),
            ms: 0,
            stop: false,
          };
          // Each row against where it was when the watch began, not the frame before: a creep under
          // 0.5 px a frame, at any frame rate, still adds up past it.
          const first = places();
          const offset = node.scrollTop;
          window.cmuxAfterPaint(() => {
            if (watch.stop) return false;
            watch.frames += 1;
            watch.ms = performance.now() - watch.started;
            for (const [id, top] of places()) {
              if (!first.has(id)) first.set(id, top);
              const before = first.get(id)!;
              if (Math.abs(top - before) > 0.5)
                watch.moves.push(
                  `frame ${watch.frames} (${Math.round(watch.ms)} ms) ${id} ${before.toFixed(1)}->${top.toFixed(1)} (offset ${node.scrollTop})`,
                );
            }
            if (Math.abs(node.scrollTop - offset) > 0.5)
              watch.offsets.push(`frame ${watch.frames} (${Math.round(watch.ms)} ms) ${offset}->${node.scrollTop}`);
            if ((window as unknown as { __followSnapshot(): { following: boolean } }).__followSnapshot().following)
              watch.following += 1;
          });
          (window as unknown as { __watch: typeof watch }).__watch = watch;
        }, TRANSCRIPT_ROW);
        // Inside the box near its left, clear of Jump to latest (which floats over the view's middle).
        await page.mouse.move(box.left + 30, box.top + Math.min(60, (box.bottom - box.top) / 2));
        // Five notches down and two up, all within the box's own scroll: none reaches its end. Each
        // notch's box and transcript offsets, for the log when it fails.
        const notches: string[] = [];
        for (const delta of [60, 60, 60, 60, 60, -60, -60]) {
          await page.mouse.wheel(0, delta);
          await painted(page, 3);
          const now = await nested(page, spec.rowId, spec.scrolls);
          notches.push(`${delta}: box ${now?.scrollTop} transcript ${(await scroller(page)).scrollTop}`);
        }
        const inside = await nested(page, spec.rowId, spec.scrolls);
        // fixed-wait: the reader rests while the turn streams on; three seconds is the case's own length.
        await page.waitForTimeout(3_000);
        const seen = await page.evaluate(() => {
          const w = window as unknown as {
            __watch: {
              moves: string[];
              offsets: string[];
              following: number;
              frames: number;
              ms: number;
              stop: boolean;
            };
            __stream: { stop(): void };
          };
          w.__stream.stop();
          w.__watch.stop = true;
          return w.__watch;
        });
        console.log(
          `scrolled-up ${name} ${kind}: ${JSON.stringify({ boxScrolled: inside?.scrollTop, frames: seen.frames, ms: Math.round(seen.ms), moves: seen.moves.slice(0, 6), offsets: seen.offsets.slice(0, 4), followingFrames: seen.following })}`,
        );
        if (!(inside && inside.scrollTop > 0)) failures.push(`the ${kind} did not scroll under the wheel`);
        // The watch spans the notches and the rest, whatever the frame rate.
        if (seen.ms < 3_000 || seen.frames < 10) failures.push(`watched ${seen.frames} frames over ${seen.ms} ms`);
        if (seen.following > 0) failures.push(`following on ${seen.following} frames`);
        if (seen.offsets.length) failures.push(`the transcript moved: ${seen.offsets.slice(0, 3).join(", ")}`);
        if (seen.moves.length) failures.push(`rows moved: ${seen.moves.slice(0, 4).join(", ")}`);
        // On a failure the log names it: every frame's move and offset, and each notch in the box.
        if (failures.length)
          console.log(
            `scrolled-up ${name} ${kind} failed: ${JSON.stringify({ notches, moves: seen.moves, offsets: seen.offsets })}`,
          );
        await page.close();
        expect(failures).toEqual([]);
      });
});
