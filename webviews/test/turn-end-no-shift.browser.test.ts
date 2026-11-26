// cmux-web-test-timeout: 300
// l10n-allow-file: test fixture prompts, replies and asks, not shipped UI.
// A turn's end moves nothing that was already on screen, in a real scroller. Leo, 2026-11-22, with a
// recording of his own chat: "IT FUCKING JUMPS ... WHEN A TURN BY AN AGENT END / STOP ADDING FUCKING
// DINGLEBERRIES OF TOOL CALLS AND BULLSHIT THAT SHIFTS POORLY. IF IT NEEDS TO SHIFT, IT SHIFTS
// MOTHERFUCKING GRACEFULLY."
//
// The rows only an ended turn used to draw -- its walkthrough, its tagged next-step card, its cut-off
// ask card -- were appended when `turn_result` arrived, at their full measured height. `shapeTurn`
// now shapes that tail while the turn is still live (turns.ts, the `concluding` parameter), so the
// end swaps nothing in.
//
// The model test (conversation/turnEndNoShift.test.ts) pins the row ids and the content's total
// height, because `layoutConversation` lays rows top-down from 0: an append at the bottom moves no
// row's `top` on either side, so a pure-model test cannot see the jump at all. It is the *scroller*
// that turns the extra height into motion: a view pinned at the content's end keeps the end in place,
// so every row on screen rises by what was appended (measured on that fixture, one harness: the ended
// turn used to end 37.75px below the live turn it replaces). This file is that half of the gate -- the
// real VirtualTranscript over the real `turnView`, in Chromium and WebKit -- in the two places the
// contract names (schemas/layout-motion/contract.json, `turn-end`: "nothing else may move because of
// it unless another event is declared"):
//
//   1. the reader at the latest message, following the end: the one motion allowed is the turn's own
//      fold, and once that has settled every row that was on screen is back where it was drawn;
//   2. the reader parked up in the earlier finished turns: nothing on screen may move at all, during
//      the end or after it.
//
// Both are gated at the contract's slack (motionContract.ts `SLACK_PX`). (1) is what gates the fix:
// with the `concluding` argument removed from `shapeTurn`'s provisional call (the base behaviour), it
// fails with every row on screen lifted 82px -- the fixture's append as the browser lays it out, the
// model's 37.75px plus the walkthrough and the live line's slot going -- and the watched row carried
// up out of the view's top half. (2) holds on base as well, and is here as the other half of the
// contract rather than as a second detector: `anchorPass` (VirtualTranscript.tsx) pins a row for a
// reader who is not following, so an append below them already moved nothing. That contradicts the
// read that a scrolled-up reader "was pushed down by the same amount": measured here, parked 900px
// above the end, they were not, on base or on head. The jump is the followed reader's alone.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { SLACK_PX } from "../src/layout/motionContract";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("turn-end-no-shift.browser.test.ts", async () => {
  setDefaultTimeout(280_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true, timeout: 30_000 })).close();
      engines.push(engine);
    } catch {
      console.warn(`turn-end-no-shift: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("a turn's end shifts nothing on screen", () => test("no engine", () => {}));
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

  type Row = {
    id: string;
    kind: string;
    text?: string;
    version: number;
    at: number;
    [key: string]: unknown;
  };
  const row = (id: string, kind: string, at: number, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    version: 1,
    at,
    ...extra,
  });
  const call = (id: string, title: string, command: string, at: number): Row =>
    row(id, "activity", at, {
      items: [
        {
          kind: "tool",
          text: title,
          tool: { id, kind: "execute", title, command, status: "completed" },
        },
      ],
    });

  /// A reply that ends on a tagged ask, which only an ended turn used to draw as a card. The fixture
  /// of conversation/turnEndNoShift.test.ts, which measured the 37.75px append on it.
  const ASK = [
    "Landed the fix and the gate is green.",
    "",
    "- **[taste]** Should the fold keep the old look?",
    "  - Keep it",
    "  - Use the new one",
  ].join("\n");

  /// Finished turns above the one that ends, tall enough to fill the view several times over: the
  /// rows a pinned bottom would lift, and the ones a parked reader sits among.
  const history = (turns: number): Row[] =>
    Array.from({ length: turns }, (_, index) => {
      const at = index * 100_000;
      return [
        row(`h${index}-user`, "user", at, {
          text: `Question ${index}: what did the keeper see?`,
        }),
        call(`h${index}-call`, "bun test", `bun test h${index}`, at + 1_000),
        row(`h${index}-answer`, "assistant", at + 2_000, {
          text:
            `## Step ${index}\n\nThe keeper climbed to the gallery and wiped the salt from the lantern ` +
            "glass, then watched the light sweep the water for a while before going back down.\n\n" +
            "- one\n- two\n- three\n",
        }),
        row(`h${index}-end`, "turnSummary", at + 3_000, {
          status: "completed",
          durationMs: 3_000,
        }),
      ];
    }).flat();

  const TURNS = 8;
  const START = TURNS * 100_000;
  /// The turn that ends: its work, then a reply marked `final_answer`, the moment its conclusion
  /// becomes knowable (turns.ts `isFinalAnswer`), whose text ends on the tagged ask.
  const ending = [
    row("p1", "user", START, { text: "Now fix the jump" }),
    call("c1", "sed -n", "sed -n '1,20p' turns.ts", START + 1_000),
    call("c2", "apply patch", "apply_patch", START + 2_000),
    row("a1", "assistant", START + 10_000, {
      text: ASK,
      assistantPhase: "final_answer",
    }),
  ];
  const summary = row("s1", "turnSummary", START + 11_000, {
    status: "completed",
    durationMs: 11_000,
    turnId: "t1",
  });

  const live = (page: Page, rows: Row[]) =>
    page.evaluate(
      (shown) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(shown),
      rows,
    );
  /// The turn's end: its `turnSummary` row arrives and the chat stops working, in one commit, as
  /// App.tsx's next snapshot does it (liveLineTakesFooterSlot.test.ts models the same swap).
  const ended = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const frames = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);

  /// Waits until three painted frames in a row draw the scroller the same and nothing animates: the
  /// turn's end fold (turnEndFold.ts) has played out and the follow motion has let the thread go.
  const settle = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<void>((done, fail) => {
          let last = "";
          let alike = 0;
          const deadline = performance.now() + 15_000;
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
            if (!scroller) return;
            // The fold and the follow chase (followChase.ts) draw the thread with Web Animations and
            // with an inline `translate` on the display's frames: while either is set, rows still move.
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
              fail(new Error("the view did not come to rest in 15 s"));
              return false;
            }
          });
        }),
    );

  type Box = { id: string; top: number; left: number; height: number };
  /// Every row drawn inside the view now, by id, with its box relative to the view: what the reader
  /// sees. Read after a painted frame, so the pane's own observers have placed the rows.
  const onScreen = (page: Page): Promise<Box[]> =>
    page.evaluate((rowSelector) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const view = scroller.getBoundingClientRect();
      return [...scroller.querySelectorAll<HTMLElement>(rowSelector)]
        .filter((node) => {
          const box = node.getBoundingClientRect();
          return box.bottom > view.top + 1 && box.top < view.bottom - 1;
        })
        .map((node) => {
          const box = node.getBoundingClientRect();
          return {
            id: node.dataset.rowId!,
            top: box.top - view.top,
            left: box.left - view.left,
            height: box.height,
          };
        });
    }, TRANSCRIPT_ROW);

  /// How far the view sits from the content's end, and how tall the content is.
  const place = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return {
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        scrollHeight: scroller.scrollHeight,
        scrollTop: scroller.scrollTop,
      };
    });

  /// The reader's wheel over the transcript.
  const wheel = async (page: Page, deltaY: number, steps = 1) => {
    const box = await page.locator(".acpmux-scroll").boundingBox();
    await page.mouse.move(box!.x + box!.width / 2, box!.y + box!.height / 2);
    for (let step = 0; step < steps; step += 1) {
      await page.mouse.wheel(0, deltaY);
      await frames(page, 2);
    }
    await settle(page);
  };

  /// What moved between two reads of the view, beyond the contract's slack, for the rows both drew.
  const shifted = (before: Box[], after: Box[]) => {
    const was = new Map(before.map((each) => [each.id, each]));
    return after
      .filter((each) => was.has(each.id))
      .map((now) => {
        const earlier = was.get(now.id)!;
        return {
          id: now.id,
          dy: now.top - earlier.top,
          dx: now.left - earlier.left,
          dh: now.height - earlier.height,
        };
      })
      .filter((each) => Math.abs(each.dy) > SLACK_PX || Math.abs(each.dx) > SLACK_PX)
      .map((each) => `${each.id} moved ${each.dy.toFixed(2)}px down, ${each.dx.toFixed(2)}px across`);
  };

  const open = async (name: string) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browsers.get(name)!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLiveRows" in window);
    return page;
  };

  for (const [name] of engines) {
    test(`${name}: a turn's end lifts nothing for a reader following the end`, async () => {
      const page = await open(name);
      const rows = [...history(TURNS), ...ending];
      await live(page, rows);
      await frames(page, 4);
      await settle(page);
      // The fixture is only worth something if the view really is at the content's end with rows
      // above the fold: the live turn drew its reply and the view follows it.
      const at = await place(page);
      expect(at.fromEnd, "the followed view sits at the content's end").toBeLessThanOrEqual(1);
      const before = await onScreen(page);
      expect(before.length, "several rows are on screen").toBeGreaterThan(2);
      // A row drawn whole, well above the bottom, and not so near the view's top that a lift would
      // carry it off screen: the lowest such row in the view's top half. A pinned bottom turns height
      // appended below it into motion of exactly this row.
      const whole = before.filter((each) => each.top >= 80 && each.top + each.height <= 350);
      const watched = whole.at(-1) ?? before.find((each) => each.top >= 0) ?? before[0]!;

      await ended(page, [...rows, summary]);
      await frames(page, 4);
      await settle(page);

      const after = await onScreen(page);
      const still = after.find((each) => each.id === watched.id);
      const report = {
        watched: watched.id,
        wasAt: Number(watched.top.toFixed(2)),
        nowAt: still ? Number(still.top.toFixed(2)) : null,
        contentWas: Math.round(at.scrollHeight),
        contentNow: Math.round((await place(page)).scrollHeight),
        shifted: shifted(before, after),
      };
      console.log(`TURN-END-NO-SHIFT followed ${name} ${JSON.stringify(report)}`);
      // The end draws nothing new, so the watched row is still on screen, in its place.
      expect(still, `${watched.id} is still on screen after the turn ended`).toBeDefined();
      expect(
        Math.abs(still!.top - watched.top),
        `${watched.id} was ${watched.top.toFixed(2)}px into the view and is now ${still!.top.toFixed(2)}px`,
      ).toBeLessThanOrEqual(SLACK_PX);
      // And it is not alone: no row the end kept on screen moved, which is the contract's `turn-end`
      // read over the whole view (the fold's own rows leave, and a row that left is not compared).
      expect(report.shifted).toEqual([]);
      await page.close();
    });

    test(`${name}: a turn's end moves nothing for a reader parked in the earlier turns`, async () => {
      const page = await open(name);
      const rows = [...history(TURNS), ...ending];
      await live(page, rows);
      await frames(page, 4);
      await settle(page);
      // Parked mid-transcript in the finished turns, far from the end and off the top: nothing of the
      // ending turn is on screen, and the view is held by its anchor, not clamped to either edge.
      await wheel(page, -900, 1);
      const at = await place(page);
      expect(at.fromEnd, "the reader is parked well above the end").toBeGreaterThan(600);
      expect(at.scrollTop, "and not clamped to the transcript's top").toBeGreaterThan(200);
      const before = await onScreen(page);
      expect(before.length, "several rows are on screen").toBeGreaterThan(2);
      expect(
        before.every((each) => !["p1", "c1", "c2", "a1"].includes(each.id)),
        "the ending turn is off screen",
      ).toBe(true);

      // Every painted frame of the end, not just where it comes to rest: up here the contract allows
      // no motion at all, during the end or after it.
      const watching = page.evaluate(
        ([rowSelector, ids]) =>
          new Promise<Record<string, number[]>>((resolve) => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const tops: Record<string, number[]> = {};
            const start = performance.now();
            window.cmuxAfterPaint(() => {
              const view = scroller.getBoundingClientRect();
              for (const node of scroller.querySelectorAll<HTMLElement>(rowSelector)) {
                const id = node.dataset.rowId!;
                if (!(ids as string[]).includes(id)) continue;
                (tops[id] ??= []).push(node.getBoundingClientRect().top - view.top);
              }
              if (performance.now() - start < 1_200) return;
              resolve(tops);
              return false;
            });
          }),
        [TRANSCRIPT_ROW, before.map((each) => each.id)] as const,
      );
      await ended(page, [...rows, summary]);
      const tops = await watching;
      await settle(page);

      const after = await onScreen(page);
      const wandered = Object.entries(tops)
        .map(([id, seen]) => ({
          id,
          by: Math.max(...seen.map((top) => Math.abs(top - seen[0]!))),
        }))
        .filter((each) => each.by > SLACK_PX)
        .map((each) => `${each.id} wandered ${each.by.toFixed(2)}px while the turn ended`);
      const report = {
        parkedAt: Math.round(at.scrollTop),
        wandered,
        shifted: shifted(before, after),
      };
      console.log(`TURN-END-NO-SHIFT parked ${name} ${JSON.stringify(report)}`);
      expect(report.shifted).toEqual([]);
      expect(report.wandered).toEqual([]);
      await page.close();
    });
  }
});
