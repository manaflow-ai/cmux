// l10n-allow-file: test fixture prompts, answers and tool titles, not shipped UI.
// cmux-web-test-timeout: 480
// 480: ten clicks per kind in both engines took 238 s alone on the Linux pool (fleet run 42785525927);
// the default 120 s killed it on every feat-cmux-next push (67 of 67), so it checked nothing.
// Every toggle in the transcript is a round trip: open then close puts the view back where it was,
// however often the reader does it (Leo, 2026-11-08: "the more I click this, the more the thing
// gradually goes down ... it's not an— what is it? idempotent action ... there's the drift, right?
// I feel like that's not good").
//
// Each kind starts shut and is clicked ten times where it is drawn:
// - away from the bottom, its row near the view's top, with no scroll between the clicks; also with
//   the prompt's top scrolled above the view, and from the keyboard;
// - at the latest row, the view at the transcript's end. An open there grows down and the view stops
//   following (Codex parity, #36940); a close there pins the bottom (Leo, 2026-11-03). When what
//   opened pushed the toggle under the composer, the reader scrolls to the end to reach it, as he must;
//   the close then puts the view back on the latest row it started on;
// - at the latest row of a running turn that appends rows between the clicks.
// After the tenth click the offset and the toggled row's place on screen must be what they were
// before the first, within a pixel. (A toggle that starts open, the latest run, is shut first: a
// close at the latest row pins the bottom and moves the rows above once, by design.)
//
// Real Chromium and WebKit from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type Page } from "playwright";
import { installPaintedFrames } from "./support/paintedFrames";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { warmViteServer } from "./support/warmDevServer";

await requireBrowserLane("transcript-toggle-round-trip-browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("transcript-toggle-round-trip-browser: skipping (run `bunx playwright install chromium`)");
    describe.skip("a toggle is a round trip", () => test("chromium", () => {}));
    return;
  }
  const { createServer } = await import("vite");
  const webviews = path.resolve(import.meta.dir, "..");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  // Both engines: the pane draws in WebKit; Chromium is the other engine CI runs.
  const engines = { chromium, webkit } as const;
  const browsers: Partial<Record<keyof typeof engines, Browser>> = {};
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

  type Row = { id: string; kind: string; text?: string; version: number; at: number; [key: string]: unknown };
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
  const output = (lines: number) =>
    Array.from({ length: lines }, (_, index) => `line ${index + 1}: the keeper trimmed the wick`).join("\n");
  const read = (id: string, lines = 30) => ({
    kind: "tool",
    text: "",
    tool: { id, title: `Read src/${id}.ts`, kind: "read", status: "completed", output: output(lines) },
  });
  const execute = (id: string, command: string) => ({
    kind: "tool",
    text: "",
    tool: { id, title: command, kind: "execute", status: "completed", command, output: "3 pass\n0 fail", exitCode: 0 },
  });
  /// A finished turn that worked first: its "Worked for" line opens to the calls.
  const turn = (index: number): Row[] => [
    row(`t${index}-user`, "user", `Question ${index}`),
    row(`t${index}-run`, "activity", undefined, { items: [read(`t${index}-a`), read(`t${index}-b`)] }),
    row(`t${index}-answer`, "assistant", paragraphs(2)),
    row(`t${index}-end`, "turnSummary", undefined, { status: "completed", durationMs: 9_000, toolCount: 2 }),
  ];
  const done = Array.from({ length: 6 }, (_, index) => turn(index)).flat();
  /// The prompt Leo pasted into (2026-11-08): typed words, then a pasted block long enough to fold.
  const pastedPrompt = (id: string) => {
    const typed = "In addition, actually:";
    // Twenty-one short lines: with the typed line past the twenty a prompt folds at, and short enough
    // that the whole message, opened, stays in the view, so its toggle is still under the pointer for
    // the next click. The paste is the message's one body (ask-14d16a6247), so its numbered lines draw
    // as the body's Markdown list, as a typed one does, taller than literal lines.
    const paste = Array.from(
      { length: 21 },
      (_, index) => `${index + 1}. The attachments fly in from the composer.`,
    ).join("\n");
    const text = `${typed}\n${paste}`;
    return row(id, "user", text, { pasted: [{ start: typed.length + 1, end: text.length }] });
  };
  const longPrompt = Array.from({ length: 23 }, (_, line) => `${line + 1}. The uploader retries on a 5xx.`).join("\n");
  const report = [
    "#34983 merged as c4580eb.",
    "",
    "- (c) found infra, not the diff. The re-bundle came from config already at the merge base.",
    "- (b): one genuine retry of a job; 412 passed, 0 failed; the later attempt was green.",
    "- Worktree and scratch removed.",
  ].join("\n");
  const raw = Array.from({ length: 4 }, () => `From fleet-mesh-3: ${report}`).join("\n");
  /// The rows each kind lives in, none of them folded into a "Worked for" (no summary closes them).
  const kinds: Row[] = [
    pastedPrompt("p-user"),
    row("p-answer", "assistant", paragraphs(1, "pilot")),
    row("k-user", "user", longPrompt),
    row("k-run", "activity", undefined, {
      items: [
        {
          kind: "thought",
          text: "Check the retry wrapper first.\n\nIt swallows the status.",
          startedAt: 0,
          endedAt: 9_000,
        },
        read("k-read"),
        execute("k-cmd-a", "bun test src/net"),
        execute("k-cmd-b", "bun test src/net --watch"),
      ],
    }),
    row("msg", "user", report, { incoming: { kind: "message", message: { name: "fleet-mesh-3", text: report, raw } } }),
  ];
  const run = '[data-row-id="k-run"] button.cv-tool.is-toggle';
  type Kind = {
    name: string;
    /// The row the toggle is in.
    row: string;
    /// Its toggle, by structure (the harness loads no string table, so labels are keys).
    toggle: string;
    /// Where the pointer clicks, when not the toggle's own box: a received message's toggle holds
    /// only its first line, which is gone while it is open, and the whole line toggles (the one
    /// message row, AgentMessageRow.tsx), so the pointer clicks the line's chevron.
    aim?: string;
    text?: string;
    not?: string;
  };
  const cases: Kind[] = [
    // A paste is part of the message's one text body, folded by its Show more (ask-14d16a6247).
    { name: "pasted text", row: "p-user", toggle: '[data-row-id="p-user"] .cv-user__more' },
    { name: "Show more", row: "k-user", toggle: '[data-row-id="k-user"] .cv-user__more' },
    { name: "Worked for", row: "worked-t5-user", toggle: '[data-row-id="worked-t5-user"] button.cv-worked' },
    { name: "Ran 2 commands", row: "k-run", toggle: `${run}:not(.cv-thought):not(.cv-command)`, not: "k-read" },
    { name: "a thought", row: "k-run", toggle: `${run}.cv-thought` },
    { name: "a tool call", row: "k-run", toggle: `${run}:not(.cv-thought):not(.cv-command)`, text: "k-read" },
    {
      name: "a received message",
      row: "msg",
      toggle: '[data-row-id="msg"] .cv-agentmsg__toggle',
      aim: '[data-row-id="msg"] .cv-agentmsg__chevron',
    },
  ];

  /// Resolves once the view is at rest: no fold running, and three painted frames in a row draw the
  /// transcript scrolled and sized as the frame before.
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
            const now = `${Math.round(scroller.scrollTop)} ${scroller.scrollHeight} ${scroller.clientHeight}`;
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
  const open = async (browser: Browser, arms?: Record<string, string>) => {
    const { port } = vite!.httpServer!.address() as { port: number };
    // Tall enough that each kind, opened, stays in the view: a toggle pushed out of it needs a scroll,
    // and a round trip here is clicks with no scroll between.
    const page = await browser.newPage({ viewport: { width: 900, height: 1000 } });
    await installPaintedFrames(page);
    // An experiment arm the gallery offers, pinned before the page's first script reads it.
    if (arms)
      await page.addInitScript((pinned) => {
        (window as unknown as { cmuxExperiments: Record<string, string> }).cmuxExperiments = pinned;
      }, arms);
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.goto(`http://127.0.0.1:${port}/test/browser/transcript-follow.html`);
    await page.waitForFunction(() => "__showRows" in window);
    return page;
  };
  /// Marks the kind's toggle (`data-toggle`), first match by its text filters; whether it is open.
  const mark = (page: Page, kind: Kind) =>
    page.evaluate(({ toggle, text, not }) => {
      for (const node of document.querySelectorAll("[data-toggle]")) node.removeAttribute("data-toggle");
      const found = [...document.querySelectorAll<HTMLElement>(toggle)].find(
        (node) =>
          node.hasAttribute("aria-expanded") &&
          (!text || node.textContent?.includes(text)) &&
          !(not && node.textContent?.includes(not)),
      );
      if (!found) return undefined;
      found.dataset.toggle = "true";
      return found.getAttribute("aria-expanded") === "true";
    }, kind);
  /// The offset and the toggled row's top on screen.
  const place = (page: Page, id: string) =>
    page.evaluate((rowId) => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const node = document.querySelector<HTMLElement>(`[data-row-id="${rowId}"]`);
      return {
        scrollTop: scroller.scrollTop,
        top: node ? node.getBoundingClientRect().top - scroller.getBoundingClientRect().top : Number.NaN,
      };
    }, id);
  /// Clicks the marked toggle where it is drawn now, as the reader's pointer does, and waits for rest.
  const click = async (page: Page, kind: Kind, reach = false, keys = false) => {
    if ((await mark(page, kind)) === undefined) throw new Error(`${kind.name}: no toggle matches`);
    // Under the composer, or under the view's end: the reader scrolls to the end to reach it.
    if (reach && !(await reachable(page))) {
      await toEnd(page);
      await mark(page, kind);
    }
    if (keys) {
      await page.evaluate(() => document.querySelector<HTMLElement>("[data-toggle]")!.focus({ preventScroll: true }));
      await page.keyboard.press("Enter");
      await settle(page);
      return;
    }
    const point = await page.evaluate((aim) => {
      const target =
        (aim && document.querySelector<HTMLElement>(aim)) || document.querySelector<HTMLElement>("[data-toggle]")!;
      const box = target.getBoundingClientRect();
      return { x: box.left + Math.min(24, box.width / 2), y: box.top + box.height / 2 };
    }, kind.aim);
    await page.mouse.click(point.x, point.y);
    await settle(page);
  };
  /// Whether the marked toggle is drawn in the part of the view the composer leaves free.
  const reachable = (page: Page) =>
    page.evaluate(() => {
      const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
      const box = document.querySelector<HTMLElement>("[data-toggle]")!.getBoundingClientRect();
      const view = scroller.getBoundingClientRect();
      const dock = parseFloat(getComputedStyle(scroller).getPropertyValue("--acpmux-dock-space")) || 0;
      return box.top >= view.top && box.bottom <= view.bottom - dock;
    });
  /// Ten clicks on `kind`'s toggle, the `between` step after each; the drift from the first click's
  /// place to the tenth's, as failures. `reach` scrolls to the end first when the toggle went under it.
  const roundTrips = async (
    page: Page,
    kind: Kind,
    label: string,
    between?: (click: number) => Promise<void>,
    reach = false,
    keys = false,
  ) => {
    const before = await place(page, kind.row);
    const opened = await mark(page, kind);
    const trace: string[] = [];
    for (let index = 0; index < 10; index += 1) {
      await click(page, kind, reach, keys);
      await between?.(index);
      const now = await place(page, kind.row);
      const state = await mark(page, kind);
      const height = await page.evaluate(
        (rowId) =>
          document.querySelector<HTMLElement>(`[data-row-id="${rowId}"]`)?.getBoundingClientRect().height ?? -1,
        kind.row,
      );
      trace.push(
        `${index + 1}: ${now.scrollTop.toFixed(1)} / ${now.top.toFixed(1)} ${state ? "open" : "shut"} h${height.toFixed(0)}`,
      );
    }
    const after = await place(page, kind.row);
    console.log(
      `${label} ${kind.name}: start ${before.scrollTop.toFixed(1)} / ${before.top.toFixed(1)}; ${trace.join("; ")}`,
    );
    const failures: string[] = [];
    if ((await mark(page, kind)) !== opened)
      failures.push(`${label} ${kind.name}: ten clicks left it in another state`);
    if (!(Math.abs(after.top - before.top) <= 1))
      failures.push(`${label} ${kind.name}: the row drifted ${(after.top - before.top).toFixed(1)}px on screen`);
    if (!between && !(Math.abs(after.scrollTop - before.scrollTop) <= 1))
      failures.push(`${label} ${kind.name}: the offset drifted ${(after.scrollTop - before.scrollTop).toFixed(1)}px`);
    return failures;
  };
  /// Shuts a kind that starts open (the latest run does), so its ten clicks start with an open.
  const shut = async (page: Page, kind: Kind) => {
    if (!(await mark(page, kind))) return;
    await page.locator("[data-toggle]").scrollIntoViewIfNeeded();
    await click(page, kind);
  };
  const show = (page: Page, rows: Row[]) =>
    page.evaluate((shown) => (window as unknown as { __showRows(rows: unknown): void }).__showRows(shown), rows);
  const toEnd = async (page: Page) => {
    await page.locator(".acpmux-scroll").evaluate((node) => {
      node.dispatchEvent(new WheelEvent("wheel", { deltaY: 1, bubbles: true }));
      node.scrollTop = node.scrollHeight;
      node.dispatchEvent(new Event("scroll"));
    });
    await settle(page);
  };

  for (const name of Object.keys(engines) as (keyof typeof engines)[]) {
    /// Each kind with its row `offset` px down the view (negative: its top scrolled above the view,
    /// its toggle still in it), clicked by pointer or from the keyboard.
    const away = async (
      name: keyof typeof engines,
      label: string,
      offset: number,
      keys: boolean,
      only?: string[],
      arms?: Record<string, string>,
    ) => {
      const failures: string[] = [];
      for (const kind of cases.filter((each) => !only || only.includes(each.name))) {
        const page = await open(browsers[name]!, arms);
        await show(page, [...done, ...kinds, row("tail", "assistant", paragraphs(14))]);
        await settle(page);
        await shut(page, kind);
        for (let attempt = 0; attempt < 4; attempt += 1) {
          await page.evaluate(
            async ({ rowId, offset }) => {
              const scroller = document.querySelector<HTMLElement>(".acpmux-scroll")!;
              for (let step = 0; step < 40 && !document.querySelector(`[data-row-id="${rowId}"]`); step += 1) {
                scroller.scrollTop -= scroller.clientHeight / 2;
                await window.cmuxPaintFrame();
              }
              const node = document.querySelector<HTMLElement>(`[data-row-id="${rowId}"]`)!;
              scroller.scrollTop += node.getBoundingClientRect().top - scroller.getBoundingClientRect().top - offset;
            },
            { rowId: kind.row, offset },
          );
          await settle(page);
        }
        failures.push(...(await roundTrips(page, kind, label, undefined, false, keys)));
        await page.close();
      }
      return failures;
    };
    test(`${name}: away from the bottom, ten clicks on each toggle put the view back where it was`, async () => {
      expect(await away(name, "away", 60, false)).toEqual([]);
    });
    test(`${name}: a prompt whose top is scrolled above the view: ten clicks on Show more put the view back`, async () => {
      expect(await away(name, "above", -160, false, ["pasted text", "Show more"])).toEqual([]);
    });
    test(`${name}: from the keyboard, ten presses on each toggle put the view back where they were`, async () => {
      expect(await away(name, "keys", 60, true)).toEqual([]);
    });

    test(`${name}: at the latest row, ten clicks on each toggle put the view back where it was`, async () => {
      const failures: string[] = [];
      for (const kind of cases) {
        const page = await open(browsers[name]!);
        // The kind's row last but a short reply, as the prompt Leo clicked sat at the chat's end; a
        // "Worked for" is its finished turn's, the last one.
        const short = row("short", "assistant", "Done.");
        const rows =
          kind.row === "worked-t5-user"
            ? done
            : kind.row === "p-user"
              ? [...done, ...kinds.slice(2), kinds[0]!, short]
              : [...done, ...kinds, short];
        await show(page, rows);
        await settle(page);
        await toEnd(page);
        await shut(page, kind);
        await toEnd(page);
        failures.push(...(await roundTrips(page, kind, "bottom", undefined, true)));
        await page.close();
      }
      expect(failures).toEqual([]);
    });

    test(`${name}: at the latest row of a running turn that appends rows, ten clicks put the view back`, async () => {
      const failures: string[] = [];
      const live = (extra: number): Row[] => [
        ...done,
        { ...pastedPrompt("live-user"), at: sent },
        row("run-a", "activity", undefined, {
          items: [execute("a1", "gh pr view 34983"), execute("a2", "gh pr checks 34983")],
        }),
        row("prose-a", "assistant", paragraphs(1, "pilot")),
        {
          ...row("msg", "user", report, {
            incoming: { kind: "message", message: { name: "fleet-mesh-3", text: report, raw } },
          }),
        },
        row("run-b", "activity", undefined, {
          items: [execute("b1", "glaeda-gh wait run 1"), execute("b2", "glaeda-gh wait run 2")],
        }),
        ...Array.from({ length: extra }, (_, index) => ({
          ...row(`more-${index}`, "assistant", paragraphs(1, "warden")),
          at: sent + 60_000 + index,
        })),
      ];
      const liveCases: Kind[] = [
        { name: "pasted text", row: "live-user", toggle: '[data-row-id="live-user"] .cv-user__more' },
        { name: "Ran 2 commands", row: "run-b", toggle: '[data-row-id="run-b"] button.cv-tool.is-toggle' },
        {
          name: "a received message",
          row: "msg",
          toggle: '[data-row-id="msg"] .cv-agentmsg__toggle',
          aim: '[data-row-id="msg"] .cv-agentmsg__chevron',
        },
      ];
      for (const kind of liveCases) {
        const page = await open(browsers[name]!);
        await page.evaluate(() => (window as unknown as { __touchDock(queued: boolean): void }).__touchDock(false));
        let extra = 0;
        await page.evaluate(
          (rows) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(rows),
          live(extra),
        );
        await settle(page);
        // A kind that starts open (the latest run does) is shut first, so the ten start with an open.
        if (await mark(page, kind)) await click(page, kind);
        await toEnd(page);
        failures.push(
          ...(await roundTrips(page, kind, "live", async () => {
            extra += 1;
            await page.evaluate(
              (rows) => (window as unknown as { __showLiveRows(rows: unknown): void }).__showLiveRows(rows),
              live(extra),
            );
            await settle(page);
          })),
        );
        await page.close();
      }
      expect(failures).toEqual([]);
    });
  }
});
