// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The Needs your input pill shows at the latest message while asks wait in other chats
// (needsYou/JumpPill.tsx). Live QA on nightly 3a63d6d: the transcript kept no room for it, so at the
// latest message the pill's box covered the running turn's live line (its timer). With the pill
// shown, the transcript keeps the pill's height and its gap above the bottom stack as room under
// its last row: the view stays at its end and the last row ends above the pill. When the pill
// hides, the room goes and the last row is back where it was.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("agent-pane-needs-you-pill-room.test.ts", async () => {
  setDefaultTimeout(120_000);
  const HARNESS = "/test/browser/needs-you-pill-room.html";
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("agent-pane-needs-you-pill-room: skipping (run `bunx playwright install chromium`)");
    describe.skip("needs you pill room", () => test("chromium", () => {}));
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
    await warmViteServer(vite, HARNESS);
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
  let at = Date.now() - 600_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  // Turns enough to fill the view, then a running turn whose live line names its read.
  const rows: Row[] = [];
  for (let turn = 1; turn <= 8; turn++)
    rows.push(
      row(`t${turn}-user`, "user", `Question ${turn}`),
      row(
        `t${turn}-answer`,
        "assistant",
        `Answer ${turn}: the checks on the merged head are green, and the notes say so.`,
      ),
      row(`t${turn}-end`, "turnSummary", undefined, { status: "completed", durationMs: 4_000 }),
    );
  rows.push(
    row("live-user", "user", "Say hello from greeting.ts"),
    row("live-run", "activity", undefined, {
      items: [
        {
          kind: "tool",
          text: "",
          tool: { id: "live-read", title: "Read greeting.ts", kind: "read", status: "in_progress" },
        },
      ],
    }),
  );

  /// Resolves after `count` painted frames.
  const painted = (page: Page, count = 4) =>
    page.evaluate(async (count) => {
      for (let left = count; left > 0; left--) await window.cmuxPaintFrame();
    }, count);
  /// The last row's box, the pill's (when shown) and the bottom stack's top, as painted.
  const measure = (page: Page) =>
    page.evaluate(
      () =>
        new Promise<{
          fromEnd: number;
          lastBottom: number;
          lastIsLive: boolean;
          dockTop: number;
          pill: { top: number; bottom: number; left: number; right: number } | null;
          intersects: boolean;
        }>((resolve) => {
          window.cmuxAfterPaint(() => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const rows = [...scroller.querySelectorAll<HTMLElement>(".acpmux-row")];
            const last = rows.reduce((a, b) =>
              Number(b.getAttribute("aria-posinset")) > Number(a.getAttribute("aria-posinset")) ? b : a,
            );
            const box = last.getBoundingClientRect();
            const pillNode = document.querySelector<HTMLElement>(".acpmux-needs-you-pill[data-shown]");
            const pill = pillNode?.getBoundingClientRect();
            const dock = document.querySelector<HTMLElement>(".harness-dock")!.getBoundingClientRect();
            resolve({
              fromEnd: Math.round(scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight),
              lastBottom: Math.round(box.bottom),
              lastIsLive: Boolean(last.textContent?.includes("greeting.ts")),
              dockTop: Math.round(dock.top),
              pill: pill ? { top: pill.top, bottom: pill.bottom, left: pill.left, right: pill.right } : null,
              intersects: Boolean(
                pill &&
                pill.top < box.bottom &&
                box.top < pill.bottom &&
                pill.left < box.right &&
                box.left < pill.right,
              ),
            });
            return false;
          });
        }),
    );

  test("at the latest message the pill keeps room: the last row ends above it, and the room goes with it", async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 640 } });
    await installPaintedFrames(page);
    await page.goto(`http://127.0.0.1:${port}${HARNESS}`);
    await page.waitForFunction(() => "__showRows" in window);
    await page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
    await page.getByText("greeting.ts", { exact: false }).first().waitFor();
    await painted(page, 8);
    const before = await measure(page);
    // The transcript overflows, opened at its latest message: the live line is the last row.
    expect({ fromEnd: before.fromEnd, lastIsLive: before.lastIsLive, pill: before.pill }).toEqual({
      fromEnd: 0,
      lastIsLive: true,
      pill: null,
    });

    // Asks open in two other chats: the pill shows at the latest message.
    await page.evaluate(() => (window as unknown as { __setAsksElsewhere(n: number): void }).__setAsksElsewhere(2));
    await page.locator(".acpmux-needs-you-pill[data-shown]").waitFor();
    await painted(page, 8);
    const shown = await measure(page);
    expect(shown.pill).not.toBeNull();
    // Still at the end, with the live line whole above the pill: no box over its text.
    expect({ fromEnd: shown.fromEnd, lastIsLive: shown.lastIsLive, intersects: shown.intersects }).toEqual({
      fromEnd: 0,
      lastIsLive: true,
      intersects: false,
    });
    expect(shown.lastBottom).toBeLessThanOrEqual(Math.round(shown.pill!.top));
    // The last row moved up by the pill's height and its gap over the stack: room kept on top of
    // the room it had.
    expect(before.lastBottom - shown.lastBottom).toBeGreaterThanOrEqual(
      Math.round(shown.dockTop - shown.pill!.top) - 1,
    );

    // The asks are answered: the pill hides and its room goes, the view still at its end.
    await page.evaluate(() => (window as unknown as { __setAsksElsewhere(n: number): void }).__setAsksElsewhere(0));
    await page.waitForFunction(() => !document.querySelector(".acpmux-needs-you-pill[data-shown]"));
    await painted(page, 8);
    const after = await measure(page);
    expect({ fromEnd: after.fromEnd, lastIsLive: after.lastIsLive, pill: after.pill }).toEqual({
      fromEnd: 0,
      lastIsLive: true,
      pill: null,
    });
    expect(Math.abs(after.lastBottom - before.lastBottom)).toBeLessThanOrEqual(1);
    await page.close();
  });
});
