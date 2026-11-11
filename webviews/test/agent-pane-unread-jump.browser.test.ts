// cmux-web-test-timeout: 300
// Jump up to the unread line (design/transcript-overlays.md, "The jump pair" and "What counts as
// seen"), in Chromium and WebKit. Leo, 2026-11-11: "if I scrolled to the bottom the whole time ...
// you eventually can jump right up to the last unread bit". The page is the real VirtualTranscript
// (browser/unread-jump.harness.tsx) with the "New" line acpmux placed where the person stopped
// attending (hub/seen.rs):
//
// - at the latest message, Jump up shows with its unread dot;
// - pressed, it lands the line near the top of the view, the first row the person did not see right
//   under it;
// - the mark survives the transcript unmounting and mounting again (a tab switch in one page), and
//   Jump up still goes to it.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import playwright, { type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { installPaintedFrames } from "./support/paintedFrames";

const ENGINES = ["chromium", "webkit"] as const;

await requireBrowserLane("agent-pane-unread-jump.browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  const launchable: (typeof ENGINES)[number][] = [];
  for (const engine of ENGINES) {
    try {
      await (await (playwright[engine] as BrowserType).launch({ headless: true })).close();
      launchable.push(engine);
    } catch {
      console.warn(`agent-pane-unread-jump: ${engine} skipped (run \`bunx playwright install ${engine}\`)`);
    }
  }
  if (launchable.length === 0) {
    describe.skip("unread jump", () => test("browsers", () => {}));
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
    await warmViteServer(vite, "/test/browser/unread-jump.html");
    for (const engine of launchable)
      browsers.set(engine, await (playwright[engine] as BrowserType).launch({ headless: true }));
  });
  afterAll(async () => {
    for (const browser of browsers.values()) await browser.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: 1,
    ...extra,
  });
  const paragraph = (index: number) =>
    `Case ${index}: the client retries a temporary transport failure, keeps the original request id, ` +
    "and stops after the last attempt, so a slow server never sees the same write twice.";
  const turns = (from: number, count: number) =>
    Array.from({ length: count }, (_, i) => [
      row(`turn-${from + i}-user`, "user", `Check retry case ${from + i}`),
      row(`turn-${from + i}-answer`, "assistant", paragraph(from + i)),
    ]).flat();
  const MARK = "unread-jump:41";
  // Fourteen turns the person saw, the line, then twelve that ended while they were away from the
  // chat on screen.
  const rows = [
    ...turns(1, 14),
    row("sinceDivider", "sinceDivider", undefined, { since: { key: MARK, seq: 41, turns: 12 } }),
    ...turns(15, 12),
  ];

  const frames = (page: Page, count = 3) =>
    page.evaluate(async (n) => {
      for (let left = n; left > 0; left -= 1) await window.cmuxPaintFrame();
    }, count);
  const open = async (engine: string) => {
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const page = await browsers.get(engine)!.newPage({ viewport: { width: 900, height: 560 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}/test/browser/unread-jump.html`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate(
      ([next, mark]) =>
        (window as unknown as { __showRows(rows: unknown, since: string): void }).__showRows(next, mark as string),
      [rows, MARK] as const,
    );
    await frames(page, 6);
    return page;
  };
  /// Jump up's state and where the line and the first unseen row draw, from the scroller's top.
  const read = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const top = scroller.getBoundingClientRect().top;
      const up = document.querySelector<HTMLElement>(".acpmux-jump-up");
      const line = document.querySelector<HTMLElement>('[data-row-id="sinceDivider"]');
      const first = document.querySelector<HTMLElement>('[data-row-id="turn-15-user"]');
      return {
        shown: up?.hasAttribute("data-shown") ?? false,
        unread: up?.hasAttribute("data-unread") ?? false,
        back: up?.hasAttribute("data-back") ?? false,
        label: up?.getAttribute("aria-label") ?? "",
        fromEnd: scroller.scrollHeight - scroller.clientHeight - scroller.scrollTop,
        line: line ? line.getBoundingClientRect().top - top : undefined,
        lineBottom: line ? line.getBoundingClientRect().bottom - top : undefined,
        first: first ? first.getBoundingClientRect().top - top : undefined,
        height: scroller.clientHeight,
      };
    });
  const press = async (page: Page) => {
    await page.click(".acpmux-jump-up");
    await frames(page, 6);
  };
  /// The line near the top: inside the view's top fifth, the first unseen row right under it.
  const landedNearTop = (at: Awaited<ReturnType<typeof read>>) => {
    expect(at.line).toBeDefined();
    expect(at.line!).toBeGreaterThanOrEqual(0);
    expect(at.line!).toBeLessThanOrEqual(at.height / 5);
    expect(at.first).toBeDefined();
    expect(at.first!).toBeGreaterThanOrEqual(at.lineBottom! - 1);
    expect(at.first!).toBeLessThan(at.height / 3);
  };

  for (const engine of ENGINES) {
    const run = launchable.includes(engine) ? test : test.skip;
    describe(engine, () => {
      run("at the latest message, Jump up shows its unread dot and lands the line near the top", async () => {
        const page = await open(engine);
        try {
          const before = await read(page);
          expect(before.fromEnd).toBeLessThanOrEqual(2);
          expect(before.shown).toBe(true);
          expect(before.unread).toBe(true);
          // The harness loads no string catalog: the key stands for "Jump up to what's new".
          expect(before.label).toMatch(/^(transcript\.jumpUnread|Jump up to what's new)$/);
          await press(page);
          const after = await read(page);
          landedNearTop(after);
          // Pressed, it holds the way back, and the dot goes with the unread target in sight.
          expect(after.back).toBe(true);
          await press(page);
          expect((await read(page)).fromEnd).toBeLessThanOrEqual(2);
        } finally {
          await page.close();
        }
      });

      run("the mark survives a remount, and Jump up still goes to it", async () => {
        const page = await open(engine);
        try {
          await page.evaluate(() => (window as unknown as { __remount(): void }).__remount());
          await frames(page, 6);
          const again = await read(page);
          expect(again.shown).toBe(true);
          expect(again.unread).toBe(true);
          await press(page);
          landedNearTop(await read(page));
        } finally {
          await page.close();
        }
      });
    });
  }
});
