// cmux-web-test-timeout: 400
// l10n-allow-file: test fixture prompts, commands and labels, not shipped UI.
// The row under the pointer is the row that lights, on the frame the pointer reaches it, while a
// turn streams (Leo, 2026-11-09, on a screen recording of a live turn's collapsed tool rows: "what's
// going on here", then "oh im mostly just saying that it lags"). In the recording the words, chevron
// and "✓ 1.9s" lit the row the pointer had left, two rows showed their times at once, and a row
// the pointer crossed quickly never lit. On base the words lifted at once, but a finished call's
// check and time and an opened group's step chevron ramped in on the 400 ms hover-dwell reveal
// (about 350 ms to full) and faded out over 180 ms; a run's summary words faded both ways over
// 120 ms; a Background tasks row's fill faded in over 80 ms.
//
// The page is the pane's dev entry talking to a stand-in acpmux daemon, a live turn streaming its
// thinking and a running command's output every 40 ms: tool rows, an opened group and its steps, a
// subagent line, and the chat's Background tasks panel. After every step (the pointer moving to a
// row, rows arriving below while the pointer stays, the reply growing under it), on the next
// painted frame the row `elementFromPoint` names is lit in full, with no fade ahead of it; a row
// the pointer left may only be on its way out, on the quick step, as a list row's hover leaves
// (pages/shared/desktop.css "Hover intent", Leo 2026-10-14); 150 ms later that row is the only one
// lit. A row is lit when any part of its hover look (words, chevron, check and time, fill) differs
// from an unhovered copy of the same row.
//
// Real Chromium and WebKit (WebKit draws the pane in cmux NEXT); CI fails the file when one cannot launch.
//
// This file tests the `runs` arm of live-turn-work, not the shipped `line` arm: the rows the pointer
// crosses are finished calls of a turn that still runs, which only `runs` draws (support/liveTurnRuns.ts).
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { pinLiveTurnRuns } from "./support/liveTurnRuns";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { papercutPane, type PapercutStep } from "./support/papercutChat";

await requireBrowserLane("agent-pane-hover-follows-row.test.ts", async () => {
  setDefaultTimeout(300_000);
  const update = (body: Record<string, unknown>, meta?: Record<string, unknown>) => ({
    method: "session/update",
    params: { sessionId: "agent-1", update: body, ...(meta && { _meta: { acpmux: meta } }) },
  });
  const call = (id: string, kind: string, title: string, rawInput: Record<string, unknown>): PapercutStep[] => [
    [
      "in",
      "tool_call",
      update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "in_progress", rawInput }),
    ],
    [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: id, status: "completed", rawOutput: { output: "ok" } }),
    ],
  ];
  const HELPER = "Review the bridge lanes";
  const HELPER_ID = "0190a000-0000-7000-8000-00000000fc01/helper-call";
  const backgroundShell = (id: string, command: string): PapercutStep[] => [
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: id,
        title: command,
        kind: "execute",
        status: "in_progress",
        rawInput: { command, run_in_background: true },
        _meta: { claude: { tool: "Bash" } },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({
        sessionUpdate: "tool_call_update",
        toolCallId: id,
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: `Command running in background with ID: ${id}` } }],
      }),
    ],
    [
      "in",
      "background_task_update",
      update({
        sessionUpdate: "background_task_update",
        taskId: `task-${id}`,
        toolCallId: id,
        command,
        state: "running",
      }),
    ],
  ];
  // The recording's list, as a live turn draws it: reads, a run of two commands (a group, opened while
  // its turn runs), a subagent, more reads, and background shells for the Background tasks panel.
  const extra: PapercutStep[] = [
    ...call("a1", "read", "Read /tmp/notes/plan.md", { file_path: "/tmp/notes/plan.md" }),
    ...call("a2", "execute", "Check for existing bridge/messaging lanes", {
      command: "ls lanes",
      description: "Check for existing bridge/messaging lanes",
    }),
    ...call("a3", "execute", "Check review logs and messaging goals", {
      command: "cat review.log",
      description: "Check review logs and messaging goals",
    }),
    [
      "in",
      "subagent_spawned",
      update(
        { sessionUpdate: "subagent_spawned", name: HELPER, background: true },
        {
          subagents: [
            {
              id: HELPER_ID,
              parent: null,
              name: HELPER,
              kind: "general-purpose",
              state: "completed",
              background: true,
            },
          ],
        },
      ),
    ],
    [
      "in",
      "tool_call",
      update({
        sessionUpdate: "tool_call",
        toolCallId: "helper-call",
        title: `Agent: ${HELPER}`,
        kind: "think",
        status: "in_progress",
        rawInput: { description: HELPER, prompt: "Review them", run_in_background: true },
      }),
    ],
    [
      "in",
      "tool_call_update",
      update({ sessionUpdate: "tool_call_update", toolCallId: "helper-call", status: "completed" }),
    ],
    ...call("a4", "read", "Read /tmp/notes/goals.md", { file_path: "/tmp/notes/goals.md" }),
    ...call("a5", "read", "Read /tmp/notes/bridge.md", { file_path: "/tmp/notes/bridge.md" }),
    ...backgroundShell("bg1", "npm run dev"),
    ...backgroundShell("bg2", "cargo watch -x test"),
    ...backgroundShell("bg3", "tail -f /tmp/review.log"),
  ];

  /// Every row a pointer can light, in the transcript and the Background tasks panel.
  const ROWS = [
    "button.cv-tool",
    ".cv-agent-activity-row",
    ".acpmux-bg__name.ui-btn",
    ".acpmux-bg__task-open.ui-btn",
    ".acpmux-bg__fold.ui-btn",
    ".acpmux-bg__counts.ui-btn",
    ".acpmux-bg__more.ui-btn",
    ".acpmux-bg__line--fold.ui-btn",
  ].join(", ");

  /// How long WebKit's own hover timer may keep a row that moved away from a still pointer hovered.
  const STILL_POINTER_WEBKIT_MS = 250;

  /// A lit row, and the parts of it still fading (empty once its look is in full).
  type Lit = { name: string; fading: string[] };
  type Look = { lit: Lit[]; under?: string };
  /// What the page painted on its latest frame: the rows whose hover look shows, with any part still
  /// on its way (a fade under way), and the row under the pointer.
  async function look(page: Page, x: number, y: number): Promise<Look> {
    return page.evaluate(
      ({ x, y, rows }) =>
        new Promise<Look>((resolve) => {
          const name = (row: Element) => {
            const html = row as HTMLElement;
            const id = html.dataset.toolId ?? html.closest<HTMLElement>("[data-tool-id]")?.dataset.toolId;
            const text = (html.innerText || html.getAttribute("aria-label") || "").split("\n")[0]!.slice(0, 48);
            return id ? `${id} ${text}` : text;
          };
          // The parts of a row's hover look, each with how it reads.
          const parts = (row: Element) => {
            const read: [string, string][] = [["fill", getComputedStyle(row).backgroundColor]];
            for (const part of row.querySelectorAll(
              ":scope > .cv-tool__text, :scope > .cv-command__text, :scope > .cv-agent-activity__sentence, .cv-tool__chevron, .cv-agent-activity__chevron, .cv-command__ok, .cv-command__time, .cv-disclosure__toggle > .cv-rotor",
            )) {
              const style = getComputedStyle(part);
              read.push([part.getAttribute("class") ?? "", `${style.color} ${style.opacity} ${style.visibility}`]);
            }
            return read;
          };
          window.cmuxAfterPaint(() => {
            const lit: Lit[] = [];
            for (const row of document.querySelectorAll(rows)) {
              const box = row.getBoundingClientRect();
              if (box.height === 0 || box.bottom < 0 || box.top > innerHeight) continue;
              // The same row, unhovered: a copy beside it, read and taken away in this task.
              const rest = row.cloneNode(true) as HTMLElement;
              rest.removeAttribute("id");
              rest.style.setProperty("position", "absolute");
              rest.style.setProperty("opacity", "0");
              rest.style.setProperty("pointer-events", "none");
              rest.style.setProperty("transition", "none");
              for (const child of rest.querySelectorAll<HTMLElement>("*"))
                child.style.setProperty("transition", "none");
              row.after(rest);
              const now = parts(row);
              const before = parts(rest);
              rest.remove();
              const changed = now.filter((part, index) => part[1] !== before[index]?.[1]);
              if (changed.length === 0) continue;
              const fading: string[] = [];
              for (const [part, value] of changed) {
                const opacity = Number(value.split(" ").at(-2));
                if (Number.isFinite(opacity) && opacity > 0 && opacity < 1)
                  fading.push(`${part} at opacity ${opacity.toFixed(2)}`);
              }
              for (const animation of row.getAnimations({ subtree: true }))
                if (animation instanceof CSSTransition && animation.playState === "running")
                  fading.push(`${animation.transitionProperty} still fading`);
              lit.push({ name: name(row), fading });
            }
            // Static status text has no row-wide hover; only its link chip is interactive.
            const control = document.elementFromPoint(x, y)?.closest("button, a, [role=button]");
            const target = control?.closest(rows);
            resolve({ lit, under: target ? name(target) : undefined });
            return false;
          });
        }),
      { x, y, rows: ROWS },
    );
  }

  /// A list row's hover look leaves on the quick step (80 ms, conversation.css --cv-row-reveal-out);
  /// by this long after a change only the row under the pointer shows one.
  const LEAVE_MS = 150;

  /// On the next painted frame the row under the pointer is lit in full, and any other lit row is
  /// one the pointer left, on its way out; once that has played, the row under the pointer is the
  /// only one lit. None is lit when the pointer is over no row.
  async function followsPointer(page: Page, point: { x: number; y: number }, step: string, first?: Look) {
    const seen = first ?? (await look(page, point.x, point.y));
    const under = seen.lit.find((row) => row.name === seen.under);
    expect({ step, under: seen.under, lit: under ?? null }).toEqual({
      step,
      under: seen.under,
      lit: seen.under ? { name: seen.under, fading: [] } : null,
    });
    const lingering = seen.lit.filter((row) => row.name !== seen.under && row.fading.length === 0);
    expect({ step, lingering }).toEqual({ step, lingering: [] });
    const start = Date.now();
    let later = await look(page, point.x, point.y);
    while (Date.now() - start < LEAVE_MS) later = await look(page, point.x, point.y);
    expect({ step, lit: later.lit }).toEqual({
      step,
      lit: later.under ? [{ name: later.under, fading: [] }] : [],
    });
  }

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  const browsers: Browser[] = [];
  const panes: Awaited<ReturnType<typeof papercutPane>>[] = [];
  afterAll(async () => {
    for (const pane of panes) await pane.close();
    for (const browser of browsers) await browser.close();
  });

  for (const [name, engine] of engines)
    describe(name, () => {
      test("the lit row follows the pointer on its next frame while a turn streams, in the transcript and the Background tasks panel", async () => {
        const browser = await engine.launch({ headless: true });
        browsers.push(browser);
        const pane = await papercutPane(() => browser, {
          turns: 1,
          running: true,
          extra,
          ready: ".cv-worked.is-below",
        });
        panes.push(pane);
        const page = await pane.open({ width: 1100, height: 900 }, pinLiveTurnRuns);
        // Hover checks target the calls inside each finished run, which now starts closed.
        for (const selector of ["[data-tool-run]", "[data-tool-group]"]) {
          const closed = page.locator(`.acpmux-activity button${selector}[aria-expanded="false"]`);
          while (await closed.count()) await closed.first().click();
        }
        // Motion on, as the app runs it: the fades under test are the app's own.
        await page.evaluate(() => (document.documentElement.dataset.cmuxMotion = "on"));
        let tick = 0;
        const stream = setInterval(() => {
          tick++;
          pane.record(
            "agent_thought_chunk",
            update({ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: `thinking ${tick} ` } }),
            "in",
          );
          if (tick % 3 === 0)
            pane.record(
              "tool_call_update",
              update({
                sessionUpdate: "tool_call_update",
                toolCallId: "r2",
                status: "in_progress",
                content: [{ type: "content", content: { type: "text", text: `line ${tick}\n` } }],
              }),
              "in",
            );
        }, 40);
        try {
          const at = async (selector: string) => {
            const target = page.locator(selector).first();
            await target.waitFor();
            const box = (await target.boundingBox())!;
            return { x: box.x + Math.min(60, box.width / 2), y: box.y + box.height / 2 };
          };
          // A sweep down the transcript's rows, then back up: each row lights on the frame the pointer
          // reaches it, and the one it left is dark in that same frame.
          const transcript = [
            'button.cv-tool[data-tool-id="a1"]',
            ".cv-steps button.cv-tool",
            ".cv-steps .cv-step:nth-child(2) button.cv-tool",
            `.cv-agent-activity-row:has-text("${HELPER}")`,
            'button.cv-tool[data-tool-id="a4"]',
            'button.cv-tool[data-tool-id="a5"]',
          ];
          for (const selector of [...transcript, ...transcript.slice().reverse()]) {
            const point = await at(selector);
            await page.mouse.move(point.x, point.y);
            await followsPointer(page, point, `pointer to ${selector}`);
          }
          // Still pointer: rows arrive below and the view follows them up, and the reply grows under
          // the list; the row now under the pointer is the lit one.
          const still = await at('button.cv-tool[data-tool-id="a4"]');
          await page.mouse.move(still.x, still.y);
          for (let n = 0; n < 4; n++) {
            for (const step of call(`late${n}`, "read", `Read /tmp/late/${n}.md`, { file_path: `/tmp/late/${n}.md` }))
              pane.record(step[1], step[2], step[0]);
            pane.record(
              "agent_message_chunk",
              update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: `Paragraph ${n}.\n\n` } }),
              "in",
            );
            await page.locator(`button.cv-tool[data-tool-id="late${n}"]`).waitFor();
            await page.evaluate(() => window.cmuxPaintFrame());
            // Chromium moves :hover to the row now under a still pointer on its next frame. WebKit does
            // it on its own hover timer, about 110 ms after the rows moved (nothing a page can make
            // sooner): until then the row that moved away keeps the hover. Either way, once hover has
            // moved, one row is lit, in full.
            const start = Date.now();
            let seen = await look(page, still.x, still.y);
            while (
              name === "webkit" &&
              Date.now() - start < STILL_POINTER_WEBKIT_MS &&
              !seen.lit.some((row) => row.name === seen.under)
            )
              seen = await look(page, still.x, still.y);
            await followsPointer(page, still, `rows arrived below a still pointer (${n})`, seen);
          }
          // The Background tasks panel: its rows light the same way while the turn streams.
          await page.getByRole("button", { name: "Chat actions" }).click();
          await page.getByRole("menuitem", { name: "Background tasks", exact: true }).click();
          const panelRows = page.locator(
            ".acpmux-bg .ui-btn:is(.acpmux-bg__name, .acpmux-bg__task-open, .acpmux-bg__fold)",
          );
          await panelRows.first().waitFor();
          const count = await panelRows.count();
          expect(count).toBeGreaterThanOrEqual(2);
          for (const index of [...Array(count).keys(), ...[...Array(count).keys()].reverse()]) {
            const box = (await panelRows.nth(index).boundingBox())!;
            const point = { x: box.x + Math.min(60, box.width / 2), y: box.y + box.height / 2 };
            await page.mouse.move(point.x, point.y);
            await followsPointer(page, point, `pointer to Background tasks row ${index}`);
          }
        } finally {
          clearInterval(stream);
        }
      });
    });
});
