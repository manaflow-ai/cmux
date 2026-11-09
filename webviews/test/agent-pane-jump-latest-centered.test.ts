// cmux-web-test-timeout: 600
// Jump to latest stands on the composer's center line (Leo, 2026-11-07: "And also the jump to bottom
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
    describe.skip("jump to latest centered on the composer", () => test("browsers", () => {}));
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
  type State = { info: SessionInfo; look?: "codex"; scrollbar?: boolean; computerUse?: boolean };

  /// The button's and the composer card's horizontal centers, as drawn.
  const centers = (page: Page) =>
    page.evaluate(() => {
      const center = (selector: string) => {
        const box = document.querySelector(selector)?.getBoundingClientRect();
        return box ? (box.left + box.right) / 2 : Number.NaN;
      };
      return {
        button: center(".acpmux-jump-latest"),
        composer: center(".acpmux-main > .acpmux-dock > .acpmux-composer > .acpmux-composer-box"),
        shown: document.querySelector(".acpmux-jump-latest")?.hasAttribute("data-shown") ?? false,
      };
    });

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

  const panel = (page: Page) => page.locator('aside.acpmux-session-info[data-presence="shown"]');
  const toggle = (page: Page) => page.locator("button.acpmux-session-info-toggle");
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
    const page = await pane!.open({ width, height: 700 }, async (page) => {
      if (state.look) await page.addInitScript((look) => localStorage.setItem("cmux.composer.look", look), state.look);
    });
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
    await page.locator(".acpmux-jump-latest[data-shown]").waitFor({ timeout: 10_000 });
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
    { info: "push", look: "codex" },
    { info: "closed", computerUse: true },
  ];

  for (const name of browsers.keys())
    test(`${name}: Jump to latest's center is the composer's at every width and state`, async () => {
      browser = browsers.get(name)!;
      const off: string[] = [];
      for (const width of widths)
        for (const state of states) {
          const page = await open(width, state);
          try {
            const seen = await centers(page);
            const label = `${width}px ${JSON.stringify(state)}`;
            expect(seen.shown, label).toBe(true);
            if (!(Math.abs(seen.button - seen.composer) <= 0.5))
              off.push(`${label}: button ${seen.button}, composer ${seen.composer}`);
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
        await page.evaluate(() => {
          const holder = window as unknown as { __centered?: number[][] };
          const frames: number[][] = [];
          holder.__centered = frames;
          const center = (selector: string) => {
            const box = document.querySelector(selector)!.getBoundingClientRect();
            return (box.left + box.right) / 2;
          };
          window.cmuxAfterPaint(() => {
            if (holder.__centered !== frames) return false;
            frames.push([
              center(".acpmux-jump-latest"),
              center(".acpmux-main > .acpmux-dock > .acpmux-composer > .acpmux-composer-box"),
            ]);
            return true;
          });
        });
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
        // The composer moved (the panel pushed it), and the button stood on its center in every frame.
        const composers = frames.map(([, composer]) => composer!);
        expect(Math.max(...composers) - Math.min(...composers)).toBeGreaterThan(50);
        const worst = Math.max(...frames.map(([button, composer]) => Math.abs(button! - composer!)));
        expect(worst).toBeLessThanOrEqual(0.5);
      } finally {
        await page.close();
      }
    });
});
