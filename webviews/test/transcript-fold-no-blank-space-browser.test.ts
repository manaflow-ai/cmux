// l10n-allow-file: test fixture prompts, replies, commands and tool titles, not shipped UI.
// A fold never leaves blank space, and a row that draws nothing takes no room (Leo, 2026-10-21: "the
// thinking not collapsing too hard but also collapsing more bullshit"). A long agent turn, with
// thoughts, tool calls with output, an edit, render calls, a background task's notification,
// bookkeeping the person never typed and another agent's message, is drawn collapsed, opened and
// collapsed again. In each state every mounted row starts where the row above it ends, and no row
// over 40px tall is mostly empty.
//
// Before: the transcript dropped a measured height of 0 as "not laid out", so a row that draws
// nothing (a step of only quiet thoughts) kept its estimate, 26px per item, as a blank band under
// an opened fold's last command; and a row whose renderer drew nothing (a render update that joined
// an earlier card) still took the row's 34px floor, one band per update between "Worked for" and
// the reply.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-fold-no-blank-space-browser.test.ts", async () => {
  setDefaultTimeout(120_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-fold-no-blank-space-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("transcript fold leaves no blank space", () => test("chromium", () => {}));
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
  const output = (lines: number) => Array.from({ length: lines }, (_, index) => `line ${index + 1}: ok`).join("\n");
  const command = (id: string, line: string, lines = 20) => ({
    kind: "tool",
    text: "",
    tool: { id, title: line, kind: "execute", status: "completed", command: line, output: output(lines) },
  });
  const read = (id: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read /tmp/${id}.txt`, kind: "read", status: "completed", output: output(40) },
  });
  const edit = (id: string) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: "Edit batch.sh",
      kind: "edit",
      status: "completed",
      diffs: [{ path: "/tmp/batch.sh", oldText: "set -e\n", newText: "set -e\necho one\necho two\n" }],
    },
  });
  /// A render call (renderCall.ts); `update` names the card it redraws, which then draws nothing.
  const render = (id: string, update?: string) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: "mcp__cmux__render",
      kind: "other",
      status: "completed",
      inputSummary: JSON.stringify({ html: `<title>Batch</title><p>${id}</p>`, ...(update && { id: update }) }),
      output: '{"rendered": true}',
    },
  });
  const thought = (text: string, ms: number) => ({ kind: "thought", text, startedAt: at, endedAt: at + ms });
  /// Short quick thoughts, which draw nothing once done (thoughts.ts isQuietThought).
  const quiet = (count: number) => Array.from({ length: count }, () => thought("ok", 5));
  const notification = (id: string) =>
    row(id, "user", "<task-notification><summary>Background command finished</summary></task-notification>", {
      incoming: { kind: "notice", text: "Background command finished" },
    });
  const reminder = (id: string) =>
    row(id, "user", "<system-reminder>bookkeeping</system-reminder>", { incoming: { kind: "hidden" } });
  const message = (id: string) =>
    row(id, "user", "[coord-deputy] The batch is next.", {
      incoming: {
        kind: "message",
        message: { name: "coord-deputy", text: "The batch is next.", raw: "[coord-deputy] The batch is next." },
      },
    });
  const summary = (id: string, durationMs: number) =>
    row(id, "turnSummary", undefined, { status: "completed", durationMs, toolCount: 3 });

  const chat: Row[] = [
    row("u1", "user", "Run the batch and report what it changed."),
    row("a1", "activity", undefined, {
      items: [
        thought("Looking at how the batch script is laid out before running it. ".repeat(4), 4_000),
        command("c1", "ls /tmp"),
        command("c2", "cat /tmp/a"),
        command("c3", "cat /tmp/b"),
        command("c4", "wc -l /tmp/c"),
      ],
    }),
    row("n1", "assistant", "Checking the script."),
    row("a2", "activity", undefined, { items: [edit("e1"), command("c5", "bash /tmp/batch32.sh", 200)] }),
    row("a3", "activity", undefined, { items: quiet(6) }),
    row("a4", "activity", undefined, {
      items: [
        read("r1"),
        command("c6", "cat /private/tmp/out.log", 80),
        render("p1"),
        render("p2", "p1"),
        render("p3", "p1"),
      ],
    }),
    row("a5", "activity", undefined, { items: quiet(4) }),
    row("ans1", "assistant", "The batch ran. It changed three files:\n\n- one\n- two\n- three"),
    summary("s1", 132_000),
    notification("u2"),
    row("a6", "activity", undefined, { items: [command("c7", "cat /private/tmp/next.log", 40)] }),
    row("a7", "activity", undefined, { items: quiet(5) }),
    row("ans2", "assistant", "The background command finished cleanly."),
    summary("s2", 9_000),
    reminder("u3"),
    row("a8", "activity", undefined, { items: [command("c8", "git status", 10)] }),
    row("ans3", "assistant", "The tree is clean."),
    summary("s3", 4_000),
    message("u4"),
    row("a9", "activity", undefined, { items: [command("c9", "gh pr list", 10)] }),
    row("ans4", "assistant", "Noted; the batch goes next."),
    summary("s4", 4_000),
  ];

  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  /// Resolves once three painted frames in a row show the transcript as the frame before, with no
  /// fold or glide running.
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
              .map((node) => `${node.dataset.rowId}@${node.style.top}+${node.style.marginTop}`)
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
  /// Every mounted row, top to bottom: where it is drawn, how tall, and how tall its visible
  /// content is (the boxes of its descendants that draw something).
  const drawnRows = (page: Page) =>
    page.evaluate(() =>
      [...document.querySelectorAll<HTMLElement>("article.acpmux-row")]
        .map((node) => {
          const box = node.getBoundingClientRect();
          let top = Number.POSITIVE_INFINITY;
          let bottom = Number.NEGATIVE_INFINITY;
          for (const child of node.querySelectorAll<HTMLElement>("*")) {
            const rect = child.getBoundingClientRect();
            const style = getComputedStyle(child);
            if (rect.width <= 0 || rect.height <= 0 || style.visibility === "hidden") continue;
            // Drawn at all: an opacity-0 ancestor (a row's Copy at rest) hides its icon too.
            if (!child.checkVisibility({ opacityProperty: true, visibilityProperty: true })) continue;
            // A wrapper with no text of its own is measured through what it holds.
            if (child.children.length > 0 && !child.textContent?.trim()) continue;
            top = Math.min(top, rect.top);
            bottom = Math.max(bottom, rect.bottom);
          }
          return {
            id: node.dataset.rowId!,
            top: box.top,
            height: box.height,
            content: bottom > top ? bottom - top : 0,
            // A turn's footer keeps its line and the turn gap at rest; its actions show on hover.
            footer: node.classList.contains("acpmux-turnSummary"),
          };
        })
        .sort((a, b) => a.top - b.top),
    );
  /// The blank bands in the transcript: a row that starts past where the row above it ends, a row
  /// that draws nothing but takes room, and a row taller than 40px whose content leaves more than
  /// 40px of it empty.
  const blankSpace = async (page: Page) => {
    const rows = await drawnRows(page);
    const gaps = rows
      .slice(1)
      .map((row, index) => ({
        after: rows[index]!.id,
        before: row.id,
        gap: row.top - rows[index]!.top - rows[index]!.height,
      }))
      .filter((each) => Math.abs(each.gap) > 1)
      .map((each) => `${Math.round(each.gap)}px between ${each.after} and ${each.before}`);
    const empty = rows
      .filter((row) => !row.footer)
      .filter((row) => (row.content === 0 ? row.height > 1 : row.height > 40 && row.height - row.content > 40))
      .map((row) => `${row.id} is ${Math.round(row.height)}px with ${Math.round(row.content)}px drawn`);
    return { ids: rows.map((row) => row.id), blank: [...gaps, ...empty] };
  };
  const open = async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    // Tall enough that every row of the chat mounts: the test reads them all.
    const page = await browser!.newPage({ viewport: { width: 900, height: 2_400 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };
  const toggle = async (page: Page) => {
    await page.click('[data-row-id="worked-u1"] button.cv-worked');
    await settle(page);
  };

  test("a long turn with notifications, bookkeeping and messages draws no blank space, folded or open", async () => {
    const page = await open();
    await show(page, chat);
    await settle(page);

    // Collapsed, the turn's work is one row: "Worked for", then the reply right under it.
    const folded = await blankSpace(page);
    expect(folded.blank).toEqual([]);
    for (const id of ["a1", "n1", "a3", "a4", "a5"]) expect(folded.ids).not.toContain(id);
    expect(folded.ids).toContain("ans1");

    await toggle(page);
    const opened = await blankSpace(page);
    expect(opened.ids).toContain("a4");
    expect(opened.blank).toEqual([]);
    // The steps of only quiet thoughts draw no element and take no room, mounted.
    const quietRows = (await drawnRows(page)).filter((row) => ["a3", "a5", "a7"].includes(row.id));
    expect(quietRows.length).toBeGreaterThan(0);
    expect(quietRows.map((row) => [row.id, row.height])).toEqual(quietRows.map((row) => [row.id, 0]));

    await toggle(page);
    const closed = await blankSpace(page);
    expect(closed.ids).not.toContain("a4");
    expect(closed.blank).toEqual([]);
    await page.close();
  });
});
