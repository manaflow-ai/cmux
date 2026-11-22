// cmux-web-test-timeout: 600
// Jump to latest stands at the composer card's end edge (jumpPlace.experiment.ts `end`, the default;
// Leo, 2026-11-21, of the disc on the tucked hat's "^ 3" pill: "didn't we say we wanted to move these
// to the side or smth?"), a fixed gap from the card's end at every width and state, in every frame
// Session Info slides. Before that it stood on the composer's center line (Leo, 2026-11-07: "And also the jump to bottom
// button is still not centered with the composer yet"). The button took the stage's middle (left:
// 50%) while the composer sits in the column between --cv-inset and --cv-inset-end: once Session Info
// pushes the column left (a wide pane), or the computer use preview takes the column's end, the
// button stood up to 164px right of the composer's center. Here, in the real pane, the button's
// center and the composer card's center are measured at a narrow, a normal and a wide pane, with
// Session Info closed, floating over the chat and pushing it, with a classic scrollbar, in both
// composer looks and with the computer use preview beside the column, and must be within 0.5px of
// each other. A last case reads every painted frame while Session Info, with Push always, slides in and
// out at the wide pane: the button moves with the composer in the same frames.
//
// CMUX_BROWSER_TESTS=1 bun test test/agent-pane-jump-latest-centered.test.ts
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, sessionInfoPushAlways } from "./support/papercutChat";
import { SESSION_INFO_SHOWN, SESSION_INFO_TOGGLE } from "../src/agent-session/acpmux/session-info/sessionInfoSelectors";
import { JUMP_LATEST, JUMP_LATEST_SHOWN } from "../src/agent-session/acpmux/transcriptSelectors";

await requireBrowserLane("agent-pane-jump-latest-centered.test.ts", async () => {
  setDefaultTimeout(300_000);
  const browsers = new Map<string, Browser>();
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      browsers.set(name, await engine.launch({ headless: true }));
    } catch {
      console.warn(`agent-pane-jump-latest-centered: skipping ${name}`);
    }
  }
  if (browsers.size === 0) {
    describe.skip("jump to latest at the composer's end", () => test("browsers", () => {}));
    return;
  }

  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    pane = await papercutPane(() => browser!, { turns: 40, running: false });
    // The first load can run Vite's dependency optimizer and reload mid-compile.
    browser = browsers.values().next().value!;
    await (await pane.open()).close();
  });
  afterAll(async () => {
    for (const one of browsers.values()) await one.close();
    await pane?.close();
  });

  type SessionInfo = "closed" | "open" | "push";
  type State = { info: SessionInfo; scrollbar?: boolean; computerUse?: boolean };

  /// The button's and the composer card's end edges, as drawn.
  const centers = (page: Page) =>
    page.evaluate(
      ({ JUMP_LATEST }) => {
        const center = (selector: string) =>
          document.querySelector(selector)?.getBoundingClientRect().right ?? Number.NaN;
        const box = document
          .querySelector(".acpmux-main > .acpmux-dock > .acpmux-composer > .acpmux-composer-box")
          ?.getBoundingClientRect();
        const main = document.querySelector(".acpmux-main")!;
        // The column's end: where the card ends when it fits (--cv-inset-end, from the pane's right).
        const columnEnd =
          main.getBoundingClientRect().right -
          (Number.parseFloat(getComputedStyle(document.querySelector(".acpmux-composer")!).paddingRight) || 0);
        const button = document.querySelector(JUMP_LATEST)?.getBoundingClientRect();
        return {
          button: center(JUMP_LATEST),
          buttonLeft: button?.left ?? Number.NaN,
          composer: center(".acpmux-main > .acpmux-dock > .acpmux-composer > .acpmux-composer-box"),
          composerMiddle: box ? box.left + box.width / 2 : Number.NaN,
          overflows: box ? box.right > columnEnd + 0.5 : false,
          shown: document.querySelector(JUMP_LATEST)?.hasAttribute("data-shown") ?? false,
        };
      },
      { JUMP_LATEST },
    );

  /// Resolves once no finite animation or transition runs and two more frames have painted.
  const settle = (page: Page) =>
    page.evaluate(async () => {
      const finite = () =>
        document.getAnimations().filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity);
      for (let tries = 0; tries < 20 && finite().some((one) => one.playState === "running"); tries++)
        await Promise.all(finite().map((animation) => animation.finished.catch(() => undefined)));
      await new Promise<void>((resolve) => {
        let painted = 0;
        window.cmuxAfterPaint(() => {
          if (++painted < 2) return true;
          resolve();
          return false;
        });
      });
    });

  const panel = (page: Page) => page.locator(SESSION_INFO_SHOWN);
  const toggle = (page: Page) => page.locator(SESSION_INFO_TOGGLE);
  /// Session Info offered (Debug Settings `agent.sessionInfo`), then open or closed.
  const sessionInfo = async (page: Page, open: boolean) => {
    await page.evaluate(() =>
      (
        window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
      ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 }),
    );
    await toggle(page).waitFor({ timeout: 10_000 });
    if ((await panel(page).count()) > 0 !== open) await toggle(page).click();
    if (open) await panel(page).waitFor({ timeout: 10_000 });
    else await panel(page).waitFor({ state: "detached", timeout: 10_000 });
  };

  const open = async (width: number, state: State) => {
    const page = await pane!.open({ width, height: 700 });
    if (state.info === "push") await sessionInfoPushAlways(page);
    if (state.info !== "closed") await sessionInfo(page, true);
    if (state.scrollbar)
      // A classic scrollbar (System Settings' "Always" in the app): the scroller takes a gutter.
      await page.addStyleTag({
        content:
          ".acpmux-scroll::-webkit-scrollbar{width:15px!important;display:block!important}.acpmux-scroll{scrollbar-width:auto!important;scrollbar-gutter:stable!important}",
      });
    if (state.computerUse)
      // The computer use preview beside the column (App.tsx sets it on .acpmux-main while one runs).
      await page.evaluate(() => document.querySelector(".acpmux-main")!.setAttribute("data-cu-preview", ""));
    // Scrolled up from the latest message: the button shows.
    await page.evaluate(() => {
      document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
    });
    await page.locator(JUMP_LATEST_SHOWN).waitFor({ timeout: 10_000 });
    await settle(page);
    return page;
  };

  const widths = [420, 900, 1600];
  const states: State[] = [
    { info: "closed" },
    { info: "open" },
    { info: "push" },
    { info: "closed", scrollbar: true },
    { info: "push", scrollbar: true },
    { info: "closed", computerUse: true },
  ];

  for (const name of browsers.keys())
    test(`${name}: Jump to latest keeps one gap from the composer's end at every width and state`, async () => {
      browser = browsers.get(name)!;
      const off: string[] = [];
      let gap: number | undefined;
      for (const width of widths)
        for (const state of states) {
          const page = await open(width, state);
          try {
            const seen = await centers(page);
            const label = `${width}px ${JSON.stringify(state)}`;
            expect(seen.shown, label).toBe(true);
            if (seen.overflows) {
              // A pane too narrow for the card beside the computer use preview: the card runs past its
              // column's end (a min width of its own), and the stack keeps to the column. It still
              // stands inside the card's end half, clear of the middle the hat's pill takes.
              if (!(seen.button <= seen.composer && seen.buttonLeft > seen.composerMiddle))
                off.push(
                  `${label}: card overflows; button ${seen.buttonLeft}-${seen.button}, ` +
                    `card middle ${seen.composerMiddle}, end ${seen.composer}`,
                );
              continue;
            }
            // Inside the card's end edge, by the same gap everywhere.
            gap ??= seen.composer - seen.button;
            if (!(gap >= 0 && Math.abs(seen.composer - seen.button - gap) <= 0.5))
              off.push(`${label}: button end ${seen.button}, composer end ${seen.composer}, gap ${gap}`);
          } finally {
            await page.close();
          }
        }
      expect(off).toEqual([]);
    });

  for (const name of browsers.keys())
    test(`${name}: the button moves with the composer in the frames Session Info slides`, async () => {
      browser = browsers.get(name)!;
      const page = await open(1600, { info: "closed" });
      try {
        // A 1600px gutter holds the panel by default, so it floats and moves nothing (Leo, 2026-11-09);
        // Push always makes it slide the column, the motion this case reads.
        await sessionInfoPushAlways(page);
        await page.emulateMedia({ reducedMotion: "no-preference" });
        await page.evaluate(
          ({ JUMP_LATEST }) => {
            const holder = window as unknown as { __centered?: number[][] };
            const frames: number[][] = [];
            holder.__centered = frames;
            const center = (selector: string) => document.querySelector(selector)!.getBoundingClientRect().right;
            window.cmuxAfterPaint(() => {
              if (holder.__centered !== frames) return false;
              frames.push([
                center(JUMP_LATEST),
                center(".acpmux-main > .acpmux-dock > .acpmux-composer > .acpmux-composer-box"),
              ]);
              return true;
            });
          },
          { JUMP_LATEST },
        );
        await sessionInfo(page, true);
        await settle(page);
        await sessionInfo(page, false);
        await settle(page);
        const frames = await page.evaluate(() => {
          const holder = window as unknown as { __centered?: number[][] };
          const frames = holder.__centered ?? [];
          holder.__centered = undefined;
          return frames;
        });
        // The composer moved (the panel pushed it), and the button kept its gap from the card's end in
        // every frame.
        const composers = frames.map(([, composer]) => composer!);
        expect(Math.max(...composers) - Math.min(...composers)).toBeGreaterThan(50);
        const gap = frames[0]![1]! - frames[0]![0]!;
        const worst = Math.max(...frames.map(([button, composer]) => Math.abs(composer! - button! - gap)));
        expect(worst).toBeLessThanOrEqual(0.5);
      } finally {
        await page.close();
      }
    });
});
