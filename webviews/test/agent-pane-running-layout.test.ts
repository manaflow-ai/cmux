// l10n-allow-file: stand-in chat text and assertions, not product copy.
// Leo: "it doesnt shift and resize the same as the other elements on the agent chat area".
// The real running row and composer must land together on a native pane/window resize; with Session
// Info open, nothing starts a web transition after native geometry has already moved (Session Info
// never moves the chat: Leo, 2026-10-29, "it's not supposed to be a fucking sidebar that pushes the
// fucking layout").
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import { mkdir } from "node:fs/promises";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { sessionInfoPushAlways, papercutPane } from "./support/papercutChat";

await requireBrowserLane("agent-pane-running-layout.test.ts", async () => {
  setDefaultTimeout(120_000);
  type Sample = {
    width: number;
    running: number;
    composer: number;
    transition: string[];
    animations: number;
  };
  const output = process.env.CMUX_RUNNING_LAYOUT_CAPTURE;
  let browser: Browser | undefined;
  let pane: Awaited<ReturnType<typeof papercutPane>> | undefined;
  beforeAll(async () => {
    if (output) await mkdir(output, { recursive: true });
  });
  afterAll(async () => {
    await pane?.close();
    await browser?.close();
  });
  const finite = (page: Page) =>
    page.evaluate(() =>
      Promise.all(
        document
          .getAnimations()
          .filter((animation) => animation.effect?.getComputedTiming().endTime !== Infinity)
          .map((animation) => animation.finished.catch(() => undefined)),
      ),
    );
  for (const [name, engine] of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    test(`${name}: a running line and composer land in the first native resize frame`, async () => {
      browser = await engine.launch({ headless: true });
      const capturedBrowser = new Proxy(browser, {
        get(target, property) {
          if (property === "newPage")
            return (options: Parameters<Browser["newPage"]>[0]) =>
              target.newPage({
                ...options,
                ...(output ? { recordVideo: { dir: output, size: { width: 1200, height: 700 } } } : {}),
              });
          return Reflect.get(target, property, target);
        },
      });
      pane = await papercutPane(() => capturedBrowser, { turns: 1, running: true, ready: ".cv-worked.is-below" });
      const page = await pane.open({ width: 1200, height: 700 });
      try {
        await page.evaluate(() => {
          document.documentElement.dataset.cmuxMotion = "on";
          (
            window as unknown as { cmuxAcpmuxBridge: { applyHeaderState(state: unknown): void } }
          ).cmuxAcpmuxBridge.applyHeaderState({ inspector: true, version: 2 });
        });
        await sessionInfoPushAlways(page, false);
        const toggle = page.locator("button.acpmux-session-info-toggle");
        await toggle.waitFor();
        if ((await page.locator("aside.acpmux-session-info").count()) === 0) await toggle.click();
        await page.locator('aside.acpmux-session-info[data-presence="shown"]').waitFor();
        await finite(page);
        // Two resizes: the first after the panel opens, then another, each landing in one frame.
        for (const width of [900, 1200]) {
          await page.evaluate((targetWidth) => {
            const samples: Sample[] = [];
            const shell = document.querySelector<HTMLElement>(".acpmux-shell")!;
            const read = (): Sample => {
              const running = document.querySelector<HTMLElement>(".cv-worked.is-below")!;
              const composer = document.querySelector<HTMLElement>(".acpmux-composer-box")!;
              const moved = [
                document.querySelector<HTMLElement>(".acpmux-spacer")!,
                composer.closest<HTMLElement>(".acpmux-composer")!,
              ];
              return {
                width: shell.clientWidth,
                running: running.getBoundingClientRect().left,
                composer: composer.getBoundingClientRect().left,
                transition: moved.map((node) => getComputedStyle(node).transitionDuration),
                animations: moved
                  .flatMap((node) => node.getAnimations())
                  .filter(
                    (animation) =>
                      animation.effect?.getComputedTiming().endTime !== Infinity && animation.playState === "running",
                  ).length,
              };
            };
            const observer = new ResizeObserver(() => {
              if (shell.clientWidth === targetWidth) samples.push(read());
            });
            observer.observe(shell);
            const painted: Sample[] = [];
            const stop = window.cmuxAfterPaint(() => {
              if (shell.clientWidth === targetWidth) painted.push(read());
              return painted.length < 20;
            });
            Object.assign(window, { __runningLayout: { samples, painted, stop, observer } });
          }, width);
          await page.setViewportSize({ width, height: 700 });
          await page.waitForFunction(
            () =>
              (window as unknown as { __runningLayout: { painted: unknown[] } }).__runningLayout.painted.length >= 20,
          );
          const result = await page.evaluate(() => {
            const state = (
              window as unknown as {
                __runningLayout: { samples: Sample[]; painted: Sample[]; stop(): void; observer: ResizeObserver };
              }
            ).__runningLayout;
            state.stop();
            state.observer.disconnect();
            return { samples: state.samples, painted: state.painted };
          });
          console.log(`RUNNING_LAYOUT ${name} ${width} ${JSON.stringify(result)}`);
          if (output) await page.screenshot({ path: `${output}/${name}-${width}.png` });
          const resize = result.samples.at(0)!;
          const first = result.painted.at(0)!;
          const last = result.painted.at(-1)!;
          expect(resize.transition).toEqual(["0s", "0s"]);
          expect(result.painted.every((sample) => sample.animations === 0)).toBe(true);
          expect(Math.abs(first.running - last.running)).toBeLessThanOrEqual(1);
          expect(Math.abs(first.composer - last.composer)).toBeLessThanOrEqual(1);
          expect(result.painted.every((sample) => Math.abs(sample.running - sample.composer) <= 1)).toBe(true);
        }
      } finally {
        const video = page.video();
        await page.close();
        if (output && video) await video.saveAs(`${output}/${name}-resize.webm`);
        await pane.close();
        pane = undefined;
        await browser.close();
        browser = undefined;
      }
    });
  }
});
