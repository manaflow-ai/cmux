// l10n-allow-file: test fixture prompts, replies, commands and notices, not shipped UI.
// The room after a finished turn's "Worked for" rule matches the references and balances the room
// before it, wherever the line draws. Leo, 2026-11-09: "ours looks like it still has a bit too much of
// a gap after the line tho lucas fixed the before but we need to reduce the after", beside two
// references: "Worked for 1m 6s ›", a hairline, then the reply.
//
// Measured on his screenshots in device px at 2x, label ink to rule and rule to the reply's ink: the
// references stand 10 then 59, and 18 then 44 (after 2.4 to 5.9 times before); ours stood 18 then 100.
// The 100 is a turn the agent ran on its own (a scheduled check's notice, then its work and reply):
// the rows under its "Worked for" carry the turn's `inBackground` and the line does not, so the reply
// read as opening the turn (model.ts opensBackgroundTurn) and stood the 32 turn gap under the line's
// own 12. Now no row opens a turn under its own "Worked for", and the line's room after its rule is the
// run gap, 16: 19 then 40 device px, as the references.
//
// Each case is checked closed and opened: a turn with calls, one with only a thought (no calls), one
// a notice started, and a background turn's. A turn whose work is only text draws no "Worked for"
// (chat-transcript.md: a reply alone draws none).
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { gridLength } from "../src/agent-session/acpmux/transcriptGrid";

await requireBrowserLane("worked-for-gap-after-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("worked-for-gap-after-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("worked for gap after", () => test("chromium", () => {}));
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
    await warmViteServer(vite, "/test/browser/transcript-follow.html");
    browser = await chromium.launch({ headless: true });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  /// The room the line keeps under its rule, box to box: the run gap.
  const AFTER_BOX = gridLength("gap-run");
  /// Rule to the next row's first text, and that over the label's text to the rule: the references'
  /// after stands 2.4 to 5.9 times their before (ink, device px: 44 over 18, 59 over 10).
  const AFTER_TEXT = { min: 17, max: 21 };
  const RATIO = { min: 2.4, max: 5.9 };

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
  const command = (id: string, line: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: line, kind: "execute", status: "completed", command: line, output: "ok" },
  });
  const thought = (text: string, ms: number) => ({ kind: "thought", text, startedAt: at, endedAt: at + ms });
  const reply = "Yes, I think there's something here worth a look, and the reply runs on past one line.";
  const calls = [command("c1", "ls"), command("c2", "cat a"), command("c3", "cat b")];
  const notice = (id: string) =>
    row(id, "user", "<task-notification><summary>Start the re-review</summary></task-notification>", {
      incoming: { kind: "notice", text: "Start the re-review at the new head" },
    });
  const opening = [
    row("u1", "user", "Run it."),
    row("ans0", "assistant", "Started."),
    row("s0", "turnSummary", undefined, { status: "completed", durationMs: 4_000, toolCount: 0 }),
  ];
  const cases: Record<string, Row[]> = {
    "a turn with calls": [
      row("u1", "user", "Run it."),
      row("a1", "activity", undefined, { items: calls }),
      row("ans1", "assistant", reply),
      row("s1", "turnSummary", undefined, { status: "completed", durationMs: 44_000, toolCount: 3 }),
    ],
    "a turn with no calls": [
      row("u1", "user", "Think it over."),
      row("a1", "activity", undefined, { items: [thought("Looking at it closely first. ".repeat(3), 6_000)] }),
      row("ans1", "assistant", reply),
      row("s1", "turnSummary", undefined, { status: "completed", durationMs: 44_000, toolCount: 0 }),
    ],
    "a turn a notice started": [
      ...opening,
      notice("u2"),
      row("a1", "activity", undefined, { items: calls }),
      row("ans1", "assistant", reply),
      row("s1", "turnSummary", undefined, { status: "completed", durationMs: 44_000, toolCount: 3 }),
    ],
    // Leo's screenshot: a scheduled check's turn, its notice, then "Worked for 44s · 3 tool calls".
    "a background turn": [
      ...opening,
      row("backgroundTurn-bg1", "backgroundTurn", undefined, {
        background: {
          id: "bg1",
          trigger: "scheduled_wakeup",
          running: false,
          quiet: false,
          reason: "result",
          hasRows: true,
          ownTurn: true,
        },
      }),
      notice("u2"),
      row("a1", "activity", undefined, { inBackground: "bg1", items: calls }),
      row("ans1", "assistant", reply, { inBackground: "bg1" }),
      row("s1", "turnSummary", undefined, {
        status: "completed",
        durationMs: 44_000,
        toolCount: 3,
        inBackground: "bg1",
      }),
    ],
  };

  /// Resolves once three painted frames in a row show the transcript as the frame before.
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
                  animation.playState === "running" && animation.effect?.getTiming().iterations !== Infinity,
              );
            const rows = [...scroller.querySelectorAll<HTMLElement>("article.acpmux-row")]
              .map((node) => `${node.dataset.rowId}@${node.style.top}+${node.getBoundingClientRect().height}`)
              .join(",");
            const now = `${scroller.scrollHeight} ${rows}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the transcript did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );

  /// Around the last "Worked for": its label's text to its rule (before), its rule to the next drawn
  /// row's box (box) and first text (after), and its row's placed height.
  const measure = (page: Page) =>
    page.evaluate(() => {
      const worked = [...document.querySelectorAll<HTMLElement>("button.cv-worked")].at(-1)!;
      const article = worked.closest<HTMLElement>("article.acpmux-row")!;
      const ruleTop = worked.getBoundingClientRect().bottom - 1;
      const label = document.createRange();
      label.selectNodeContents(worked.querySelector(".cv-worked__label")!);
      const rows = [...document.querySelectorAll<HTMLElement>("article.acpmux-row")]
        .filter((node) => node.getBoundingClientRect().height > 1)
        .sort((a, b) => a.getBoundingClientRect().top - b.getBoundingClientRect().top);
      const next = rows[rows.indexOf(article) + 1]!;
      const walker = document.createTreeWalker(next, NodeFilter.SHOW_TEXT, {
        acceptNode: (node) => (node.textContent?.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
      });
      const text = document.createRange();
      text.selectNodeContents(walker.nextNode()!);
      return {
        open: worked.getAttribute("aria-expanded") === "true",
        next: next.dataset.rowId,
        before: ruleTop - label.getBoundingClientRect().bottom,
        box: next.getBoundingClientRect().top - (ruleTop + 1),
        after: text.getClientRects()[0]!.top - (ruleTop + 1),
        // The row the stack placed: its top to the next row's top, against its own drawn height.
        pitch: next.getBoundingClientRect().top - article.getBoundingClientRect().top,
        height: article.getBoundingClientRect().height,
      };
    });

  for (const [name, rows] of Object.entries(cases)) {
    test(`${name}: the room after the Worked for rule is the references', closed and opened`, async () => {
      const { port } = vite!.httpServer!.address() as { port: number };
      const page = await browser!.newPage({ viewport: { width: 760, height: 1_000 } });
      await installPaintedFrames(page);
      await page.emulateMedia({ reducedMotion: "reduce" });
      await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
      await page.waitForFunction(() => "__showRows" in window);
      await page.evaluate(
        (shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown),
        rows,
      );
      await settle(page);
      for (const state of ["closed", "opened"] as const) {
        if (state === "opened") {
          await page.locator("button.cv-worked").last().click();
          await settle(page);
        }
        const got = await measure(page);
        const where = `${name}, ${state} (${JSON.stringify(got)})`;
        expect(got.open, where).toBe(state === "opened");
        expect(got.next, where).toBe(state === "opened" ? "a1" : "ans1");
        expect(got.box, where).toBeCloseTo(AFTER_BOX, 0);
        expect(got.after, where).toBeGreaterThanOrEqual(AFTER_TEXT.min);
        expect(got.after, where).toBeLessThanOrEqual(AFTER_TEXT.max);
        expect(got.after / got.before, where).toBeGreaterThanOrEqual(RATIO.min);
        expect(got.after / got.before, where).toBeLessThanOrEqual(RATIO.max);
        // No stack gap under the line: the row's placed pitch is its drawn height, the estimate's.
        expect(got.pitch, where).toBeCloseTo(got.height, 0);
        expect(got.height, where).toBeCloseTo(gridLength("gap-foot") + 22 + AFTER_BOX, 0);
      }
      await page.close();
    });
  }
});
