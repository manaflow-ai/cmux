// l10n-allow-file: test fixture prompts, answers and agent names, not shipped UI.
// Opening and closing a row at the very bottom of a running turn never jitters (Leo, 2026-11-05:
// "simply STOP JITTERING IT", then "the bottom pin is literally the point ... it pushes text up AND
// DOESN'T MOVE ANYTHING BELOW BEFORE OR AFTER", and "when you get >like 50-70% up the screen from the
// bottom then it starts doing it normally expanding down").
//
// The view sits at the latest row of a running turn with the composer over its foot. Every painted
// frame of each toggle is read: where each row is drawn, and when the frame painted.
// - Near the bottom (the line clicked is under BOTTOM_PIN_SHARE of the view up from its foot): every
//   row under the toggled one stays on its pixel in every frame, the bottom with it, and the rows
//   above move one way only, the clicked line with them.
// - Further up: the clicked line and every row above it stay on their pixels, and the rows under it
//   move one way only.
// Each toggle's close puts every row back where it was before the open.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";
import { BOTTOM_PIN_SHARE } from "../src/agent-session/acpmux/conversation/foldAnchor";

await requireBrowserLane("transcript-details-toggle-steady-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-details-toggle-steady-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("a toggle at the bottom never jitters", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  // Both engines: the pane draws in WebKit; Chromium is the other engine CI runs.
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
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
    for (const name of Object.keys(engines) as (keyof typeof engines)[])
      browsers[name] = await engines[name].launch({ headless: true });
  });
  afterAll(async () => {
    for (const each of Object.values(browsers)) await each?.close();
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
  const sent = Date.now() - 180_000;
  let at = sent - 3_600_000;
  const row = (id: string, kind: string, text?: string, extra: Record<string, unknown> = {}): Row => ({
    id,
    kind,
    text,
    version: 1,
    at: (at += 1_000),
    ...extra,
  });
  const paragraphs = (count: number, word = "keeper") =>
    Array.from(
      { length: count },
      (_, index) =>
        `Paragraph ${index}. The ${word} climbed to the gallery and wiped the salt from the lantern glass, ` +
        "then watched the light sweep the water for a while before going back down.",
    ).join("\n\n");
  const done = Array.from({ length: 6 }, (_, index) => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
  ]).flat();
  const report = [
    "#34983 merged as c4580eb.",
    "",
    "- (c) found infra, not the diff. The re-bundle came from config already at the merge base.",
    "- (b): one genuine retry of a job; 412 passed, 0 failed; the later attempt was green.",
    "- Worktree and scratch removed.",
  ].join("\n");
  const raw = Array.from({ length: 4 }, () => `From fleet-mesh-3: ${report}`).join("\n");
  const call = (id: string, command: string, lines = 6) => ({
    kind: "tool",
    text: "",
    tool: {
      id,
      title: command,
      kind: "execute",
      status: "completed",
      command,
      output: Array.from({ length: lines }, (_, index) => `line ${index + 1}: ok`).join("\n"),
      startedAt: sent + 5_000,
    },
  });
  /// A running turn: a run of commands, prose, another agent's message (opened, its Details shut), a
  /// second run of commands, more prose, then the live line. The message and the second run sit a few
  /// rows over the bottom; the first run sits higher up.
  const live: Row[] = [
    ...done,
    { ...row("live-user", "user", "Forward swallowed replies and check the fleet."), at: sent },
    row("run-a", "activity", undefined, {
      items: [call("a1", "gh pr view 34983"), call("a2", "gh pr checks 34983"), call("a3", "git log -3")],
    }),
    row("prose-a", "assistant", paragraphs(2, "pilot")),
    row("msg", "user", report, {
      incoming: { kind: "message", message: { name: "fleet-mesh-3", text: report, raw } },
    }),
    row("prose-b", "assistant", paragraphs(1, "warden")),
    row("run-b", "activity", undefined, {
      items: [call("b1", "glaeda-gh wait run 1"), call("b2", "glaeda-gh wait run 2"), call("b3", "gh pr list")],
    }),
    row("prose-c", "assistant", "The latest-base replacements are now waiting on their checks."),
  ];

  /// Resolves once the view is at rest: no fold running, and three painted frames in a row draw
  /// every row where the frame before did.
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
              .map((node) => `${node.dataset.rowId}@${Math.round(node.getBoundingClientRect().top)}`)
              .join(",");
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${rows}`;
            alike = !moving && now === last ? alike + 1 : 0;
            last = now;
            if (alike >= 3) {
              done();
              return false;
            }
            if (performance.now() > deadline) {
              fail(new Error(`the view did not come to rest in 10 s (moving: ${moving})`));
              return false;
            }
          });
        }),
    );
  type Frame = {
    /// When the frame painted (ms).
    t: number;
    /// Each drawn row's top in the viewport, by id.
    rows: Record<string, number>;
    /// The clicked line's top.
    line: number;
    scrollTop: number;
    /// How long after its frame the read ran (ms).
    lag?: number;
  };
  /// One frame at 60 Hz.
  const FRAME_MS = 1000 / 60;
  /// Clicks the element `selector` finds and reads every painted frame for `ms`, from the frame
  /// before the click.
  const clickAndWatch = async (page: Page, selector: string, ms = 700) => {
    const point = await page.evaluate((query) => {
      const node = document.querySelector<HTMLElement>(query);
      if (!node) throw new Error(`nothing matches ${query}`);
      document.querySelector("[data-probe]")?.removeAttribute("data-probe");
      node.dataset.probe = "true";
      const box = node.getBoundingClientRect();
      return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
    }, selector);
    const read = () =>
      page.evaluate(() => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
        const rows: Record<string, number> = {};
        for (const node of scroller.querySelectorAll<HTMLElement>("article.acpmux-row"))
          if (node.getBoundingClientRect().height > 0) rows[node.dataset.rowId!] = node.getBoundingClientRect().top;
        return {
          t: performance.now(),
          rows,
          line: document.querySelector<HTMLElement>("[data-probe]")!.getBoundingClientRect().top,
          scrollTop: scroller.scrollTop,
        };
      });
    const before = await read();
    const watching = page.evaluate(
      (duration) =>
        new Promise<Frame[]>((resolve) => {
          const start = performance.now();
          const frames: Frame[] = [];
          window.cmuxAfterPaint((t) => {
            const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
            const rows: Record<string, number> = {};
            for (const node of scroller.querySelectorAll<HTMLElement>("article.acpmux-row"))
              if (node.getBoundingClientRect().height > 0) rows[node.dataset.rowId!] = node.getBoundingClientRect().top;
            const line = document.querySelector<HTMLElement>("[data-probe]");
            frames.push({
              t,
              rows,
              line: line?.getBoundingClientRect().top ?? Number.NaN,
              scrollTop: scroller.scrollTop,
              lag: performance.now() - t,
            });
            if (performance.now() - start < duration) return;
            resolve(frames);
            return false;
          });
        }),
      ms,
    );
    await page.mouse.click(point.x, point.y);
    const frames = await watching;
    await settle(page);
    // A read that ran a frame or more after its frame (the next frame's callbacks ran first) sees that
    // next frame's state, not the one it painted: it is no read of its frame, and is left out, as a
    // frame the browser skipped is.
    const late = frames.filter((frame) => frame.lag! > FRAME_MS);
    if (late.length)
      console.log(
        `${selector}: ${late.length} late read(s) left out, at ${late.map((frame) => `${(frame.t - frames[0]!.t).toFixed(0)}ms (+${frame.lag!.toFixed(0)}ms)`).join(", ")}`,
      );
    // Too few reads left would let a jump pass unseen: the run is no measure then.
    if (late.length * 2 > frames.length)
      throw new Error(`${selector}: ${late.length} of ${frames.length} reads ran late; the frames are not measured`);
    return { frames: [before, ...frames.filter((frame) => !(frame.lag! > FRAME_MS))], rest: await read() };
  };
  const viewBox = (page: Page) =>
    page.evaluate(() => {
      const box = document.querySelector<HTMLElement>(".acpmux-scroll")!.getBoundingClientRect();
      return { top: box.top, bottom: box.bottom, height: box.height };
    });
  const atLatest = (page: Page) =>
    page.evaluate(() => {
      const node = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      return node.scrollHeight - node.clientHeight - node.scrollTop <= 2;
    });
  /// The ids of the rows drawn at `frame`, top to bottom.
  const order = (frame: Frame) =>
    Object.entries(frame.rows)
      .sort((a, b) => a[1] - b[1])
      .map(([id]) => id);
  /// How far `values` turn back on themselves (a move one way, then the other, by more than half a
  /// pixel). Frame gaps never count: only the direction of each painted step does.
  const reversals = (values: number[]) => {
    let direction = 0;
    const turns: string[] = [];
    for (let index = 1; index < values.length; index += 1) {
      const step = values[index]! - values[index - 1]!;
      if (Math.abs(step) <= 0.5) continue;
      const sign = Math.sign(step);
      if (direction !== 0 && sign !== direction) turns.push(`frame ${index}: ${step.toFixed(1)}px`);
      direction = sign;
    }
    return turns;
  };
  /// Painted frames mid-motion that drew nothing new: the fold stalled a frame and then jumped to
  /// catch up. A frame the browser never painted is no read here, so it never counts.
  const stalls = (values: number[]) => {
    const moving = values.map((value, index) => index > 0 && Math.abs(value - values[index - 1]!) > 0.5);
    const first = moving.indexOf(true);
    const last = moving.lastIndexOf(true);
    const found: string[] = [];
    for (let index = first + 1; first >= 0 && index < last; index += 1)
      if (!moving[index]) found.push(`frame ${index}`);
    return found;
  };
  /// The rows of `ids` that moved off their pixel at the first frame, in any frame.
  const moved = (frames: Frame[], ids: string[]) =>
    ids.flatMap((id) => {
      const from = frames[0]!.rows[id];
      if (from === undefined) return [];
      const worst = frames.reduce((most, frame) => {
        const top = frame.rows[id];
        return top === undefined ? most : Math.max(most, Math.abs(top - from));
      }, 0);
      return worst > 0.5 ? [`${id} moved ${worst.toFixed(1)}px`] : [];
    });
  const trace = (label: string, frames: Frame[], ids: string[]) =>
    console.log(
      [`${label}: ms | scrollTop | line | ${ids.join(" | ")}`]
        .concat(
          frames.map(
            (frame) =>
              `${(frame.t - frames[0]!.t).toFixed(0)} | ${frame.scrollTop.toFixed(1)} | ${frame.line.toFixed(1)} | ` +
              ids.map((id) => frame.rows[id]?.toFixed(1) ?? "-").join(" | "),
          ),
        )
        .join("\n"),
    );
  const open = async () => {
    const { port } = vite!.httpServer!.address() as { port: number };
    const page = await browser!.newPage({ viewport: { width: 900, height: 700 } });
    await installPaintedFrames(page);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showLiveRows" in window);
    // The composer over the view's foot, as the pane draws it while a turn runs.
    await page.evaluate(() => (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(false));
    await page.evaluate(
      (rows) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(rows),
      live,
    );
    await settle(page);
    // The message opens to its text first (its line is the click), as in the recording.
    await page.click('[data-row-id="msg"] .cv-disclosure__toggle');
    await settle(page);
    return page;
  };
  const DETAILS = '[data-row-id="msg"] .cv-received__more';
  const RUN_B = '[data-row-id="run-b"] [aria-expanded]';
  const RUN_A = '[data-row-id="run-a"] [aria-expanded]';
  /// The clicked line's height up from the view's foot, as a share of the view.
  const upShare = async (page: Page, selector: string) => {
    const view = await viewBox(page);
    const top = await page.evaluate(
      (query) => document.querySelector<HTMLElement>(query)!.getBoundingClientRect().top,
      selector,
    );
    return (view.bottom - top) / view.height;
  };

  /// Whether the disclosure `selector` finds is open now.
  const expanded = (page: Page, selector: string) =>
    page.evaluate(
      (query) => document.querySelector<HTMLElement>(query)!.getAttribute("aria-expanded") === "true",
      selector,
    );

  /// Two clicks on one toggle near the bottom, an open and a close in whichever order its state gives:
  /// the rows under the toggled one never move, the rows above move one way, and the clicked line
  /// rises as its row opens and comes down as it closes.
  const pinnedToggle = async (page: Page, label: string, selector: string, toggled: string) => {
    const failures: string[] = [];
    for (let click = 0; click < 2; click += 1) {
      const phase = (await expanded(page, selector)) ? "close" : "open";
      if (phase === "open") {
        const share = await upShare(page, selector);
        if (!(share < BOTTOM_PIN_SHARE))
          failures.push(`${label}: the line is ${(share * 100).toFixed(0)}% up, not near the bottom`);
      }
      if (!(await atLatest(page))) failures.push(`${label} ${phase}: the view is not at the latest row`);
      const { frames, rest } = await clickAndWatch(page, selector);
      const ids = order(frames[0]!);
      const at = ids.indexOf(toggled);
      const below = ids.slice(at + 1);
      const above = ids.slice(0, at + 1);
      trace(`${label} ${phase}`, frames, [...above.slice(-2), ...below]);
      for (const each of moved(frames, below)) failures.push(`${label} ${phase}: under the row, ${each}`);
      const lineTurns = reversals(frames.map((frame) => frame.line));
      if (lineTurns.length) failures.push(`${label} ${phase}: the clicked line turned back at ${lineTurns.join(", ")}`);
      const lineStalls = stalls(frames.map((frame) => frame.line));
      if (lineStalls.length) failures.push(`${label} ${phase}: the clicked line stalled at ${lineStalls.join(", ")}`);
      for (const id of above) {
        const turns = reversals(
          frames.map((frame) => frame.rows[id]).filter((top): top is number => top !== undefined),
        );
        if (turns.length) failures.push(`${label} ${phase}: ${id} turned back at ${turns.join(", ")}`);
      }
      if (!(await atLatest(page))) failures.push(`${label} ${phase}: the view left the latest row`);
      const travel = rest.line - frames[0]!.line;
      if (phase === "open" && !(travel < -1))
        failures.push(`${label} open: the clicked line did not rise (${travel.toFixed(1)}px)`);
      if (phase === "close" && !(travel > 1))
        failures.push(`${label} close: the clicked line did not come down (${travel.toFixed(1)}px)`);
    }
    return failures;
  };

  for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
    test(`${name}: near the bottom: Details and a run of commands open and close with nothing under them moving`, async () => {
      browser = browsers[name];
      const page = await open();
      const failures = [
        ...(await pinnedToggle(page, "Details", DETAILS, "msg")),
        ...(await pinnedToggle(page, "run of commands", RUN_B, "run-b")),
        // Again, the message's Details after the run's fold, as Leo toggled it back and forth.
        ...(await pinnedToggle(page, "Details again", DETAILS, "msg")),
      ];
      expect(failures).toEqual([]);
      await page.close();
    });

    test(`${name}: up the screen from the bottom: the clicked line and the rows above it stay, the rows under it move`, async () => {
      browser = browsers[name];
      const page = await open();
      // A line high in the view, at the latest row: the run at the turn's start, brought into the top
      // part of the view by a taller viewport's worth of rows under it.
      await page.setViewportSize({ width: 900, height: 1100 });
      await settle(page);
      // The run starts shut, so the click opens it (a shut at the bottom pins the bottom, as ever).
      if (await expanded(page, RUN_A)) {
        await page.click(RUN_A);
        await settle(page);
      }
      const failures: string[] = [];
      const share = await upShare(page, RUN_A);
      if (!(share > BOTTOM_PIN_SHARE))
        failures.push(`the run is ${(share * 100).toFixed(0)}% up, not above the threshold`);
      if (!(await atLatest(page))) failures.push("the view is not at the latest row");
      // Opening: the line and every row above it stay; the rows under it move down, one way.
      const opened = await clickAndWatch(page, RUN_A);
      const ids = order(opened.frames[0]!);
      const at = ids.indexOf("run-a");
      const above = ids.slice(0, at + 1);
      const below = ids.slice(at + 1);
      trace("up the screen open", opened.frames, [...above.slice(-2), ...below.slice(0, 4)]);
      for (const each of moved(opened.frames, above)) failures.push(`open: over the line, ${each}`);
      const lineMoved = Math.max(...opened.frames.map((frame) => Math.abs(frame.line - opened.frames[0]!.line)));
      if (lineMoved > 0.5) failures.push(`open: the clicked line moved ${lineMoved.toFixed(1)}px`);
      for (const id of below) {
        const values = opened.frames.map((frame) => frame.rows[id]).filter((top): top is number => top !== undefined);
        const turns = reversals(values);
        if (turns.length) failures.push(`open: ${id} turned back at ${turns.join(", ")}`);
      }
      const next = below[0];
      if (next && !((opened.rest.rows[next] ?? 0) > (opened.frames[0]!.rows[next] ?? 0) + 1))
        failures.push(`open: ${next} under the line did not move down`);
      // Closing: no row turns back, and every row ends where it was before the open.
      const closed = await clickAndWatch(page, RUN_A);
      trace("up the screen close", closed.frames, [...above.slice(-2), ...below.slice(0, 4)]);
      for (const id of ids) {
        const turns = reversals(
          closed.frames.map((frame) => frame.rows[id]).filter((top): top is number => top !== undefined),
        );
        if (turns.length) failures.push(`close: ${id} turned back at ${turns.join(", ")}`);
      }
      for (const id of [...above.slice(-3), ...below.slice(0, 3)]) {
        const was = opened.frames[0]!.rows[id];
        const now = closed.rest.rows[id];
        if (was !== undefined && now !== undefined && Math.abs(now - was) > 1)
          failures.push(`close: ${id} ended ${(now - was).toFixed(1)}px off where it was before the open`);
      }
      expect(failures).toEqual([]);
      await page.close();
    });

    test(`${name}: away from the bottom: Details open and close in place`, async () => {
      browser = browsers[name];
      const page = await open();
      // Scrolled up by the reader's own wheel, 160px off the latest row, so the view stops following;
      // the message's Details stay in view.
      const view = await viewBox(page);
      await page.mouse.move(450, view.top + view.height / 2);
      for (let step = 0; step < 4; step += 1) {
        await page.mouse.wheel(0, -40);
        await page.evaluate(() => window.cmuxPaintFrame());
      }
      await settle(page);
      const failures: string[] = [];
      if (await atLatest(page)) failures.push("the view is still at the latest row");
      const details = await page.evaluate(
        (query) => document.querySelector<HTMLElement>(query)!.getBoundingClientRect(),
        DETAILS,
      );
      if (!(details.top > view.top && details.bottom < view.bottom)) failures.push("the Details are out of view");
      for (const phase of ["open", "close"] as const) {
        const { frames } = await clickAndWatch(page, DETAILS);
        const ids = order(frames[0]!);
        const above = ids.slice(0, ids.indexOf("msg") + 1);
        trace(`away ${phase}`, frames, above.slice(-3));
        const lineMoved = Math.max(...frames.map((frame) => Math.abs(frame.line - frames[0]!.line)));
        if (lineMoved > 0.5) failures.push(`${phase}: the clicked line moved ${lineMoved.toFixed(1)}px`);
        for (const each of moved(frames, above)) failures.push(`${phase}: over the line, ${each}`);
      }
      expect(failures).toEqual([]);
      await page.close();
    });
  }
});
