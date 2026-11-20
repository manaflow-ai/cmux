// l10n-allow-file: test fixture commands and replies, not shipped UI.
// Leo, 2026-11-17: a big empty band under an expanded group, and rows shifting while scrolling. An
// opened run of tool calls draws its steps in a scroll box 224 px tall (RunScroll.tsx, the default
// "box" arm), and the transcript places a row it has not measured yet at its estimate (model.ts
// `fallbackRowHeight`, through `foldedRunSteps`). Base estimated a folded run the reader opened at its
// closed line, 22 px. Here a run of 200 commands is opened in the real transcript, and the estimate the
// transcript itself computes for it (its `layoutConversation`, imported into the page) is within a few
// px of the height it draws. Base: 22 against 250.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("opened-run-estimate-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`opened-run-estimate-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("opened run estimate", () => test("no engine", () => {}));
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
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const STEPS = 200;
  /// A finished run of `STEPS` shell commands in a "Worked for", as turns.ts shapes it: folded, its line closed.
  const run = row("big-run", "activity", undefined, {
    settled: true,
    foldRun: true,
    items: Array.from({ length: STEPS }, (_, index) => ({
      kind: "tool",
      text: `rg -n "index" src/sidebar${index}.ts`,
      tool: {
        id: `cmd-${index}`,
        title: `rg -n "index" src/sidebar${index}.ts`,
        kind: "execute",
        status: "completed",
        command: `rg -n "index" src/sidebar${index}.ts`,
        output: "ok\n",
        exitCode: 0,
      },
    })),
  });
  const rows: Row[] = [
    ...Array.from({ length: 6 }, (_, index) => [
      row(`t${index}-user`, "user", `Question ${index}`),
      row(`t${index}-answer`, "assistant", `Answer ${index}. The keeper wiped the salt from the lantern glass.`),
    ]).flat(),
    row("run-user", "user", "Find where the sidebar's drag reorder loses its index."),
    run,
    row("after-answer", "assistant", "The index is read before the drop moves the row; the fix reads it after."),
  ];

  const showSession = (page: Page, id: string, shown: Row[]) =>
    page.evaluate(
      ([session, list]) =>
        (window as unknown as { __showSession(id: string, rows: unknown): void }).__showSession(session, list),
      [id, shown] as const,
    );
  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  /// The run's row, in the view's coordinates (null: not mounted).
  const boxes = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const top = scroller.getBoundingClientRect().top;
      const box = (id: string) => {
        const node = scroller.querySelector<HTMLElement>(`.acpmux-row[data-row-id="${id}"]`);
        if (!node) return null;
        const rect = node.getBoundingClientRect();
        return { top: rect.top - top, bottom: rect.bottom - top, height: rect.height, width: rect.width };
      };
      return { run: box("big-run") };
    });

  for (const [name] of engines) {
    test(`${name}: an opened run of ${STEPS} commands is estimated at the height it draws`, async () => {
      const page = await browsers.get(name)!.newPage({ viewport: { width: 1100, height: 800 } });
      await installPaintedFrames(page);
      const { port } = vite!.httpServer!.address() as { port: number };
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showSession" in window);
      await showSession(page, "session-1", rows);
      await painted(page, 10);

      // The reader opens the run: its line, then its steps in the 224 px box.
      const line = page.locator('.acpmux-row[data-row-id="big-run"] .cv-tool.is-toggle').first();
      await line.waitFor();
      await line.click();
      await page.locator('.acpmux-row[data-row-id="big-run"] .cv-run-scroll').waitFor();
      // The fold plays; read the run once its height has held for 6 painted frames.
      let last = -1;
      for (let held = 0, frames = 0; held < 6 && frames < 240; frames += 1) {
        await painted(page);
        const height = (await boxes(page)).run?.height ?? -1;
        held = Math.abs(height - last) < 0.01 ? held + 1 : 0;
        last = height;
      }
      const drawn = (await boxes(page)).run!;
      // The transcript's own estimate for the run, at the width it lays rows out at (the row's width).
      const estimated = await page.evaluate(
        async ([shown, width]) => {
          const model = (await import(
            /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/model.ts`
          )) as typeof import("../src/agent-session/acpmux/model");
          return model.layoutConversation(
            [shown as never],
            width,
            undefined,
            undefined,
            undefined,
            undefined,
            "session-1",
          ).heights[0]!;
        },
        [run, drawn.width] as const,
      );
      console.log(`opened-run-estimate ${name}: estimated ${estimated} px, drawn ${drawn.height} px`);
      expect(Math.abs(estimated - drawn.height)).toBeLessThanOrEqual(4);

      await page.close();
    });
  }
});
