// l10n-allow-file: test fixture prompts and the stand-in bar's text, not shipped UI.
// The bar of running background shells above the composer (subagents/SubagentTray.tsx, the running
// tray) coming or going moves no transcript row in one frame while the view follows the latest row
// (Leo, softened: "the chat jumps 30-70 px at the bottom"). Before, the rows jumped by the bar's whole
// height in the frame it came: 28 px for its one-line header, 56 px for two. The newest row still
// ends the rest gap over the bar on every frame (model.ts REST_GAP, agent-pane-composer-rest-gap), so
// the bar grows its height from 0 as it enters and the rows follow it home in small steps.
// The bar is put in the floating stack where App.tsx draws the tray and enters as the tray does
// (`data-tray-enter` with its laid-out height in `TRAY_ENTER_HEIGHT`: it grows from 0 as it fades and
// rises 4 px), and leaves as the
// tray does (a copy in its place folds its height to 0, trayMotionModel.ts `playTrayExit`); the
// transcript sees it through the stack's size, as it sees the real one. Real Chromium against the pane's dev entry and a stand-in
// acpmux (support/papercutChat.ts); CI fails the file when it cannot launch it (requireBrowserLane).
// Locally:
//   CMUX_BROWSER_TESTS=1 bun test test/agent-pane-dock-bar-still.test.ts
// With CMUX_FRAMES_DIR set it writes stills before the bar, its first frame, and once settled.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane } from "./support/papercutChat";
import { TRANSCRIPT_ROW } from "../src/agent-session/acpmux/transcriptSelectors";
import { TRAY_ENTER_ATTR, TRAY_ENTER_HEIGHT, TRAY_GHOST } from "../src/agent-session/acpmux/subagents/trayMotionModel";

await requireBrowserLane("agent-pane-dock-bar-still.test.ts", async () => {
  setDefaultTimeout(300_000);
  let browser: Browser;
  let pane: Awaited<ReturnType<typeof papercutPane>>;
  beforeAll(async () => {
    browser = await chromium.launch({ headless: true });
    pane = await papercutPane(() => browser, { turns: 40, running: false });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });

  /// Puts a running-tray bar of `lines` header lines in the stack (or takes it out) and returns, for
  /// each frame painted after, how far the rows in view before it are drawn from where they were
  /// (signed, the row that moved most), and the newest row's gap over the stack once it settles.
  const change = (page: Page, lines: number, add: boolean) =>
    page.evaluate(
      async ({ lines, add, rowSelector, enterAttr, heightVar, ghostClass }) => {
        const tops = () =>
          new Map(
            [...document.querySelectorAll<HTMLElement>(rowSelector)].map((row) => [
              row.dataset.rowId!,
              row.getBoundingClientRect().top,
            ]),
          );
        const view = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
        const before = new Map([...tops()].filter(([, top]) => top > view.top && top < view.bottom));
        const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
        if (add) {
          // The tray's box: a section in the stack, one 28 px header line per line.
          const bar = document.createElement("section");
          bar.className = "acpmux-running-tray";
          bar.dataset.testBar = "";
          for (let line = 0; line < lines; line++) {
            const row = document.createElement("div");
            row.style.height = "28px";
            row.textContent = line === 0 ? "bun run dev --port 4300 0s" : "bun run dev --port 4301 0s";
            bar.append(row);
          }
          dock.insertBefore(bar, dock.querySelector(":scope > .acpmux-composer"));
          // It enters as the tray does when it appears in a chat that showed without it
          // (trayMotionModel.ts `useTrayMotion`): its laid-out height read, then the mark, both gone at
          // the entrance's end.
          bar.style.setProperty(heightVar, `${bar.offsetHeight}px`);
          bar.setAttribute(enterAttr, "");
          bar.addEventListener(
            "animationend",
            () => {
              bar.removeAttribute(enterAttr);
              bar.style.removeProperty(heightVar);
            },
            { once: true },
          );
        } else {
          // It leaves as the tray does (trayMotionModel.ts `playTrayExit`): a copy in its place folds its
          // height to 0 while the card itself is gone.
          const bar = dock.querySelector<HTMLElement>("[data-test-bar]")!;
          const ghost = bar.cloneNode(true) as HTMLElement;
          ghost.removeAttribute("data-test-bar");
          ghost.removeAttribute(enterAttr);
          ghost.classList.add(ghostClass);
          Object.assign(ghost.style, {
            height: `${bar.offsetHeight}px`,
            minHeight: "0",
            boxSizing: "border-box",
            overflow: "hidden",
            flexShrink: "0",
          });
          ghost.addEventListener("animationend", () => ghost.remove(), { once: true });
          bar.replaceWith(ghost);
        }
        const moved: number[] = [];
        for (let frame = 0; frame < 24; frame++) {
          await window.cmuxPaintFrame();
          const now = tops();
          let most = 0;
          for (const [id, top] of before) {
            const by = (now.get(id) ?? Infinity) - top;
            if (Math.abs(by) > Math.abs(most)) most = by;
          }
          moved.push(Math.round(most * 10) / 10);
        }
        const rows = [...document.querySelectorAll<HTMLElement>(rowSelector)];
        const last = rows.reduce((a, b) =>
          a.getBoundingClientRect().bottom > b.getBoundingClientRect().bottom ? a : b,
        );
        const stackTop = Math.min(
          ...[...dock.children]
            .flatMap((part) => (part.classList.contains("acpmux-composer") ? [...part.children] : [part]))
            .map((part) => part.getBoundingClientRect())
            .filter((box) => box.height > 0)
            .map((box) => box.top),
        );
        return {
          moved,
          rows: before.size,
          bar: dock.querySelector("[data-test-bar]")?.getBoundingClientRect().height ?? 0,
          gap: Math.round((stackTop - last.getBoundingClientRect().bottom) * 10) / 10,
        };
      },
      {
        lines,
        add,
        rowSelector: TRANSCRIPT_ROW,
        enterAttr: TRAY_ENTER_ATTR,
        heightVar: TRAY_ENTER_HEIGHT,
        ghostClass: TRAY_GHOST,
      },
    );

  /// The largest move between two painted frames, the frame of the change included.
  const largestStep = (moved: number[]) =>
    Math.max(...moved.map((by, frame) => Math.abs(by - (frame === 0 ? 0 : moved[frame - 1]!))));

  for (const width of [900, 420])
    for (const lines of [1, 2])
      test(`a ${lines}-line bar coming and going above the composer moves no row in one frame (${width} px)`, async () => {
        const page = await pane.open({ width, height: 700 });
        const frames = process.env.CMUX_FRAMES_DIR;
        const still = (name: string) =>
          frames ? page.screenshot({ path: `${frames}/dock-bar-${width}px-${lines}line-${name}.png` }) : undefined;
        try {
          const at = await page.evaluate(() => {
            const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            return node.scrollHeight - node.clientHeight - node.scrollTop;
          });
          // The view follows the latest row.
          expect(at).toBeLessThanOrEqual(2);
          await still("0-without");
          if (frames) {
            // A still of the first painted frame with the bar: every animation paused there.
            await page.evaluate(
              async ({ lines, enterAttr, heightVar }) => {
                const dock = document.querySelector<HTMLElement>(".acpmux-dock")!;
                const bar = document.createElement("section");
                bar.className = "acpmux-running-tray";
                bar.dataset.stillBar = "";
                for (let line = 0; line < lines; line++) {
                  const row = document.createElement("div");
                  row.style.height = "28px";
                  row.textContent = `bun run dev --port ${4300 + line} 0s`;
                  bar.append(row);
                }
                dock.insertBefore(bar, dock.querySelector(":scope > .acpmux-composer"));
                bar.style.setProperty(heightVar, `${bar.offsetHeight}px`);
                bar.setAttribute(enterAttr, "");
                await window.cmuxPaintFrame();
                await window.cmuxPaintFrame();
                for (const animation of document.getAnimations()) animation.pause();
              },
              { lines, enterAttr: TRAY_ENTER_ATTR, heightVar: TRAY_ENTER_HEIGHT },
            );
            await still("1-first-frame");
            await page.evaluate(async () => {
              for (const animation of document.getAnimations()) animation.play();
              for (let frame = 0; frame < 30; frame++) await window.cmuxPaintFrame();
              document.querySelector("[data-still-bar]")!.remove();
              for (let frame = 0; frame < 30; frame++) await window.cmuxPaintFrame();
            });
          }
          const came = await change(page, lines, true);
          await still("2-settled");
          const went = await change(page, lines, false);
          const report = {
            width,
            lines,
            bar: came.bar,
            cameFirstFrame: came.moved[0],
            cameLargestStep: largestStep(came.moved),
            cameSettled: came.moved.at(-1),
            cameGap: came.gap,
            wentFirstFrame: went.moved[0],
            wentLargestStep: largestStep(went.moved),
            wentSettled: went.moved.at(-1),
            wentGap: went.gap,
          };
          console.log(`DOCK-BAR ${JSON.stringify(report)}`);
          console.log(`DOCK-BAR-FRAMES ${JSON.stringify({ width, lines, came: came.moved, went: went.moved })}`);
          expect(came.rows).toBeGreaterThan(3);
          // The bar took room in the stack (it is not an empty stand-in).
          expect(came.bar).toBeGreaterThanOrEqual(28 * lines - 1);
          // The frame the bar comes or goes draws every row where it was.
          expect(Math.abs(came.moved[0]!)).toBeLessThanOrEqual(0.5);
          expect(Math.abs(went.moved[0]!)).toBeLessThanOrEqual(0.5);
          // Then they go on the house settle (fast first, `--cmux-ease-settle`): no frame takes the whole
          // bar, and the move spans several frames.
          expect(report.cameLargestStep).toBeLessThanOrEqual(came.bar * 0.6);
          expect(report.wentLargestStep).toBeLessThanOrEqual(came.bar * 0.6);
          const settling = (moved: number[]) => moved.filter((by) => Math.abs(Math.abs(by) - came.bar) > 1).length;
          expect(settling(came.moved)).toBeGreaterThanOrEqual(4);
          expect(settling(went.moved)).toBeGreaterThanOrEqual(4);
          // Settled, the newest row rests the rest gap over the stack, the bar's top while it shows.
          expect(Math.abs(Math.abs(came.moved.at(-1)!) - came.bar)).toBeLessThanOrEqual(1);
          expect(Math.abs(Math.abs(went.moved.at(-1)!) - came.bar)).toBeLessThanOrEqual(1);
          expect(Math.abs(came.gap - went.gap)).toBeLessThanOrEqual(1);
        } finally {
          await page.close();
        }
      });
});
