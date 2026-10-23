// l10n-allow-file: test fixture prompts, replies and tool titles, not shipped UI.
// A running Codex-style fold puts its live line directly under the folded tool row. The line's
// disappearance when the turn settles must leave the streamed answer on the same pixel.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-live-line-gap-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-live-line-gap-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript live line gap", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/transcript-live-line-gap.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: 1_000,
    ...extra,
  });
  const command = (id: string, title: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title, kind: "execute", status: "completed", command: title, output: "ok" },
  });
  const runningRows = (answer?: Row): Row[] => [
    row("prompt", "user", "Run the checks."),
    row("run", "activity", undefined, { items: [command("one", "git status"), command("two", "bun test")] }),
    ...(answer ? [answer] : []),
  ];
  const endedRows = runningRows(row("answer", "assistant", "All checks passed.", { streaming: false })).concat(
    row("summary", "turnSummary", undefined, { status: "completed", durationMs: 5_000, toolCount: 2 }),
  );
  const show = (page: Page, rows: Row[], isRunning = true) =>
    page.evaluate(
      ({ shown, running }) =>
        (window as unknown as { __showRows(rows: unknown[], isRunning: boolean): void }).__showRows(shown, running),
      { shown: rows, running: isRunning },
    );
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
                  animation.playState === "running" && animation.effect?.getComputedTiming().iterations !== Infinity,
              );
            const rows = [...scroller.querySelectorAll<HTMLElement>("article.acpmux-row")]
              .map((node) => `${node.dataset.rowId}@${node.style.transform}`)
              .join(",");
            const now = `${scroller.scrollHeight} ${rows}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the transcript did not settle in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  const open = async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 720 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-live-line-gap.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };

  test("a running folded tool row uses the tool rhythm before its live line", async () => {
    const page = await open();
    await show(page, runningRows());
    await settle(page);
    const spacing = await page.evaluate(() => {
      const fold = document.querySelector<HTMLElement>('[data-row-id="run"] .cv-tool');
      const line = document.querySelector<HTMLElement>('[data-row-id="thinking-live"] .cv-thinking');
      if (!fold || !line) throw new Error("folded tool row or live line did not render");
      const expected = Number.parseFloat(
        getComputedStyle(document.documentElement).getPropertyValue("--cv-tool-run-bottom-gap"),
      );
      return { gap: line.getBoundingClientRect().top - fold.getBoundingClientRect().bottom, expected };
    });
    expect(spacing.gap).toBeCloseTo(spacing.expected, 0);
    await page.close();
  });

  test("removing the live line after streaming leaves the answer settled on its pixel", async () => {
    const page = await open();
    await show(page, runningRows(row("answer", "assistant", "All checks passed.", { streaming: true })));
    await settle(page);
    const whileStreaming = await page.locator('[data-row-id="answer"]').boundingBox();
    expect(whileStreaming).not.toBeNull();
    await show(page, endedRows, false);
    await settle(page);
    const afterSettled = await page.locator('[data-row-id="answer"]').boundingBox();
    expect(afterSettled).not.toBeNull();
    expect(Math.abs(afterSettled!.y - whileStreaming!.y)).toBeLessThanOrEqual(1);
    expect(await page.locator('[data-row-id="thinking-live"]').count()).toBe(0);
    await page.close();
  });
});
