// l10n-allow-file: test fixture commands and replies, not shipped UI.
// Leo, 2026-11-17: a gap under a row of tool calls, and rows shifting when it is measured. A row of
// tool calls that is not a folded run (a turn with no summary yet, a run kept as it is) draws its calls
// as ToolRows groups them (TurnRows.tsx): a run of commands is one "Ran N commands" group, open by
// default, its steps in the 224 px scroll box (RunScroll.tsx). model.ts `fallbackRowHeight` summed a
// line per call instead: 20 commands were estimated at 440 px against 250 drawn, 200 at 4,400.
// Here the transcript's own estimate (its `layoutConversation`, imported into the page) is compared
// with the row it draws, and a long chat is scrolled to such a row it had not mounted: its scroll
// height must not jump by the estimate's error when the row mounts.
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("plain-run-estimate-browser.test.ts", async () => {
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
      console.warn(`plain-run-estimate-browser: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }
  if (engines.length === 0) {
    describe.skip("plain run estimate", () => test("no engine", () => {}));
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
  let at = 0;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const command = (index: number) => ({
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
  });
  /// A finished row of `steps` commands, not a folded run (no `foldRun`): a turn with no summary.
  const run = (steps: number) =>
    row("plain-run", "activity", undefined, {
      items: Array.from({ length: steps }, (_, index) => command(index)),
    });

  const showSession = (page: Page, id: string, shown: Row[]) =>
    page.evaluate(
      ([session, list]) =>
        (
          window as unknown as {
            __showSession(id: string, rows: unknown): void;
          }
        ).__showSession(session, list),
      [id, shown] as const,
    );
  const painted = (page: Page, count = 1) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  const runBox = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>('.acpmux-scroll .acpmux-row[data-row-id="plain-run"]');
      if (!node) return null;
      const rect = node.getBoundingClientRect();
      return { height: rect.height, width: rect.width };
    });
  /// The transcript's own estimate for `shown`, at the width it lays rows out at (the row's width).
  const estimate = (page: Page, shown: Row, width: number) =>
    page.evaluate(
      async ([one, w]) => {
        const model = (await import(
          /* @vite-ignore */ `${location.origin}/src/agent-session/acpmux/model.ts`
        )) as typeof import("../src/agent-session/acpmux/model");
        return model.layoutConversation([one as never], w, undefined, undefined, undefined, undefined, "session-1")
          .heights[0]!;
      },
      [shown, width] as const,
    );
  const open = async (name: string, rows: Row[]) => {
    const page = await browsers.get(name)!.newPage({ viewport: { width: 1100, height: 800 } });
    await installPaintedFrames(page);
    const { port } = vite!.httpServer!.address() as { port: number };
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showSession" in window);
    await showSession(page, "session-1", rows);
    await painted(page, 10);
    return page;
  };

  for (const [name] of engines)
    test(`${name}: a plain row of commands is estimated at the height it draws (3, 20, 60, 200 calls)`, async () => {
      const off: Record<number, number> = {};
      for (const steps of [3, 20, 60, 200]) {
        const shown = run(steps);
        const page = await open(name, [
          row("run-user", "user", "Find where the sidebar's drag reorder loses its index."),
          shown,
          row("after-answer", "assistant", "The index is read before the drop moves the row."),
        ]);
        try {
          const drawn = (await runBox(page))!;
          const estimated = await estimate(page, shown, drawn.width);
          console.log(
            `plain-run-estimate ${name} commands ${steps}: estimated ${estimated} px, drawn ${drawn.height} px`,
          );
          off[steps] = Math.round(estimated - drawn.height);
        } finally {
          await page.close();
        }
      }
      // Each size's estimate less its drawn height, to the px.
      expect(off).toEqual({ 3: 0, 20: 0, 60: 0, 200: 0 });
    });

  // The row the estimate places is out of the mounted window (at the top of a long chat that opens
  // at its end); scrolled to, it mounts at its drawn height, and the transcript's scroll height moves
  // by what the estimate was off. Base: 4,400 against 250, a 4,150 px jump.
  for (const [name] of engines)
    test(`${name}: scrolling a long chat to a plain run of 200 commands it had not mounted keeps its scroll height`, async () => {
      const shown = run(200);
      const page = await open(name, [
        row("run-user", "user", "Find where the sidebar's drag reorder loses its index."),
        shown,
        ...Array.from({ length: 60 }, (_, index) => [
          row(`t${index}-user`, "user", `Question ${index}`),
          row(`t${index}-answer`, "assistant", `Answer ${index}. The keeper wiped the salt from the lantern glass.`),
        ]).flat(),
      ]);
      try {
        expect(await runBox(page)).toBeNull();
        const before = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight);
        await page.evaluate(() => {
          document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollTop = 0;
        });
        await page.locator('.acpmux-row[data-row-id="plain-run"]').waitFor();
        await painted(page, 12);
        const after = await page.evaluate(() => document.querySelector<HTMLElement>(".acpmux-scroll")!.scrollHeight);
        console.log(`plain-run-estimate ${name} scroll height: ${before} px before it mounted, ${after} px after`);
        expect(Math.abs(after - before)).toBeLessThanOrEqual(4);
      } finally {
        await page.close();
      }
    });
});
