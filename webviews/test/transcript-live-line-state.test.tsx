// l10n-allow-file: test fixture commands and replies, not shipped UI.
// The running turn's live line names what the turn does now, and its clock reads as the turn's
// whole time once the turn is past its first step. Leo, 2026-11-03: "i think the "thinking"
// accounting is also off pretty frequently", on "Thinking 1h 24m 7s" for a turn that had spent
// nearly all of its 1.5 h waiting on its foreground subagents, and an "Opened 1 agent session" step
// that read 1h 22m 31s for a 3.5 min call.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import type { Subagent } from "../src/agent-session/acpmux/subagents/subagentFold";
import { SUBAGENTS } from "../src/agent-session/acpmux/subagents/subagentFold";
import { Thinking } from "../src/agent-session/acpmux/conversation/Thinking";
import { WorkingCountsContext } from "../src/agent-session/acpmux/conversation/WorkingFor";
import { THINKING, trayWaitAgents, turnView } from "../src/agent-session/acpmux/conversation/turns";
import { withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";
import longWait from "../src/agent-session/acpmux/conversation/LongSubagentWait.gallery";
import { GALLERY_NOW } from "../src/gallery/clock";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (id: string, status = "completed", extra: Partial<Tool> = {}): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id, startedAt: at, ...extra },
});
const agent = (id: string, state: string, extra: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name: id,
  state,
  startedAt: at,
  ...extra,
});
const codex = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true, liveRuns: true, lineBelow: true });
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();
const drawn = (line: AcpmuxRow, now: number) =>
  words(
    renderToStaticMarkup(
      <Thinking
        since={line.at}
        now={() => now}
        doing={line.doing}
        doingAt={line.doingAt}
        doingShell={line.doingShell}
        done={line.doingDone}
        doneMs={line.doingForMs}
        liveState={line.liveState}
        liveAgents={line.liveAgents}
        thoughtMs={line.thoughtMs}
        turnTotal={line.turnTotal}
        untimed={line.untimed}
        quietKey={line.quietKey}
        quietAt={line.quietAt}
      />,
    ),
  );

test('a turn waiting on its foreground subagents says so, with the turn\'s time beside it and no "total"', () => {
  const user = row("u", "user");
  const line = codex([
    user,
    row("a", "assistant", { text: "Starting two reviewers." }),
    row("g", SUBAGENTS, { subagents: [agent("review-a", "running"), agent("review-b", "running")] }),
  ]).at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, liveState: "subagents", liveAgents: 2, turnTotal: true });
  expect(drawn(line, user.at + 5_047_000)).toBe("Waiting on 2 subagents 1h 24m 7s");
});

// With the running tray (the default) the groups leave the transcript for the tray, so the pane
// counts the wait from the rows before that (App.tsx `trayAgents`).
test("with the running tray the line still says it waits on the subagents the tray shows", () => {
  const rows = [
    row("u0", "user"),
    row("g0", SUBAGENTS, { subagents: [agent("stale", "running")] }),
    row("s0", "turnSummary", { status: "cancelled" }),
    row("u", "user"),
    row("a", "assistant", { text: "Starting two reviewers." }),
    row("g", SUBAGENTS, {
      subagents: [
        agent("review-a", "running"),
        agent("review-b", "running"),
        agent("bg", "running", { background: true }),
      ],
    }),
    row("r", "activity", { items: [call("cat app.ts")] }),
  ];
  const shown = withSubagentLines(rows);
  expect(shown.some((shaped) => shaped.kind === SUBAGENTS)).toBe(false);
  expect(trayWaitAgents(rows)).toBe(2);
  const line = turnView(shown as AcpmuxRow[], new Set(), {
    working: true,
    liveRuns: true,
    lineBelow: true,
    trayAgents: trayWaitAgents(rows),
  }).at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, liveState: "subagents", liveAgents: 2 });
  expect(line.doing).toBeUndefined();
});

// A shell call's agent keeps its card in the rows the tray draws, where the line counts it: the
// tray's count leaves it out, so it is counted once. A prompt still waiting to send opens no turn.
test("with the tray a shell call's agent counts once, and a queued prompt keeps the wait", () => {
  const rows = [
    row("u", "user"),
    row("g", SUBAGENTS, { subagents: [agent("review-a", "running")] }),
    row("run", SUBAGENTS, { subagents: [agent("shell-agent", "running", { command: "acpmux new" })] }),
    row("r", "activity", { items: [call("cat app.ts")] }),
    row("q", "user", { pending: true }),
  ];
  expect(trayWaitAgents(rows)).toBe(1);
  const line = turnView(withSubagentLines(rows) as AcpmuxRow[], new Set(), {
    working: true,
    liveRuns: true,
    lineBelow: true,
    trayAgents: trayWaitAgents(rows),
  }).find((shaped) => shaped.kind === THINKING)!;
  expect(line).toMatchObject({ liveState: "subagents", liveAgents: 2 });
});

test("background and finished subagents are no wait", () => {
  const line = codex([
    row("u", "user"),
    row("g", SUBAGENTS, {
      subagents: [agent("bg", "running", { background: true }), agent("done", "completed"), agent("fg", "running")],
    }),
  ]).at(-1)!;
  expect(line).toMatchObject({ liveState: "subagents", liveAgents: 1 });
  const none = codex([
    row("u", "user"),
    row("g", SUBAGENTS, { subagents: [agent("bg", "running", { background: true })] }),
  ]).at(-1)!;
  expect(none.liveState).toBeUndefined();
});

test("a call in flight still names the call, over any subagent wait", () => {
  const line = codex([
    row("u", "user"),
    row("g", SUBAGENTS, { subagents: [agent("fg", "running")] }),
    row("run", "activity", { items: [call("bun test", "in_progress")] }),
  ]).at(-1)!;
  expect(line).toMatchObject({ doing: "bun test", doingShell: true });
  expect(line.liveState).toBeUndefined();
});

test("a finished step reads its own time, not the turn's", () => {
  const user = row("u", "user");
  const started = user.at + 4_950_000;
  const line = codex([
    user,
    row("run", "activity", {
      items: [
        call("cmux app_agent_open_tab", "completed", {
          kind: "other",
          command: undefined,
          title: "Opened 1 agent session",
          startedAt: started,
          endedAt: started + 207_000,
        }),
      ],
    }),
  ]).at(-1)!;
  expect(line).toMatchObject({ doing: "Opened 1 agent session", doingDone: true, doingForMs: 207_000 });
  expect(drawn(line, user.at + 4_951_000)).toBe("Opened 1 agent session 3m 27s · 1h 22m 31s");
});

test("an answer paused mid-stream reads Writing, not Thinking", () => {
  const user = row("u", "user");
  const run = row("run", "activity", { items: [call("git log")] });
  const reply = row("a", "assistant", { text: "So" });
  const line = codex([user, run, reply]).at(-1)!;
  expect(line).toMatchObject({ liveState: "writing", turnTotal: true, quietAt: reply.at });
  expect(drawn(line, reply.at + 2_000)).toBe(`Writing ${(reply.at + 2_000 - user.at) / 1_000}s`);
});

// A chat opened (or the gallery's stage mounted) long after its reply paused: the line reads
// Thinking from its first frame, not Writing for WRITING_MS from the open (agent-pane.transcript
// #working-tokens waited 5 s for its Thinking line on feat-cmux-next).
test("an answer that paused long before the line mounted reads Thinking at once", () => {
  const user = row("u", "user");
  const run = row("run", "activity", { items: [call("git log")] });
  const reply = row("a", "assistant", { text: "So" });
  const line = codex([user, run, reply]).at(-1)!;
  expect(drawn(line, reply.at + 60_000)).toStartWith("Thinking");
});

test("before the turn's first output it still reads Thinking with the turn's time", () => {
  const user = row("u", "user");
  const line = codex([user]).at(-1)!;
  expect(line.turnTotal).toBeUndefined();
  expect(drawn(line, user.at + 18_000)).toBe("Thinking 18s");
});

test("the long-wait gallery entry's live line names its subagents and the turn's total", () => {
  const rows = longWait.variants["waiting-on-subagents"]!.snapshot.rows;
  const line = codex(rows).at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, liveState: "subagents", liveAgents: 3 });
  expect(drawn(line, GALLERY_NOW)).toBe("Waiting on 3 subagents 1h 24m 7s");
  const step = codex(longWait.variants["finished-step"]!.snapshot.rows).at(-1)!;
  expect(drawn(step, GALLERY_NOW)).toBe("Opened 1 agent session 3m 27s · 1h 24m 7s");
});

test("a running call reads the turn's clock as its total, never a clock that starts at the call", () => {
  // Leo, 2026-11-01: "it should just keep going" (transcript-live-line-continuous-browser.test.ts).
  const start = 1_000_000;
  const html = renderToStaticMarkup(
    <Thinking since={start} doing="bun test" doingShell doingAt={start + 5_000} turnTotal now={() => start + 13_000} />,
  );
  expect(words(html)).toBe("Running bun test 13s");
  expect(html).toContain('<span class="cv-worked__time">13s</span>');
});

test("waiting on subagents, the line does not count them a second time", () => {
  const start = 1_000_000;
  const counts = { agents: 2, commands: 1, sessions: 0, openAgents() {}, openCommands() {}, openSessions() {} };
  const html = renderToStaticMarkup(
    <WorkingCountsContext.Provider value={counts}>
      <Thinking since={start} liveState="subagents" liveAgents={2} turnTotal now={() => start + 60_000} />
    </WorkingCountsContext.Provider>,
  );
  expect(words(html)).toBe("Waiting on 2 subagents 1m · 1 command");
});

test("Thinking past the first step shows only the thoughts' streamed time, the waits go to the total", () => {
  // Leo's sample, 2026-11-03: "Thinking 7m 34s · ↓ 4.5K out ↑ 1.4M in", 7.5 min of "thinking" for
  // 4.5K output tokens. The calls, waits and queue time between thoughts are not thinking.
  const user = row("u", "user");
  const t0 = user.at;
  const line = codex([
    user,
    row("t1", "activity", {
      items: [{ kind: "thought", text: "Read the helper first.", startedAt: t0 + 1_000, endedAt: t0 + 4_000 }],
    }),
    row("run", "activity", {
      items: [call("cargo test", "completed", { startedAt: t0 + 5_000, endedAt: t0 + 400_000 })],
    }),
    row("t2", "activity", {
      items: [{ kind: "thought", text: "The retry path is next.", startedAt: t0 + 449_000, endedAt: t0 + 454_000 }],
    }),
  ]).at(-1)!;
  expect(line).toMatchObject({ kind: THINKING, thoughtMs: 8_000, turnTotal: true });
  expect(line.doing).toBeUndefined();
  expect(drawn(line, t0 + 454_000)).toBe("Thinking 8s · 7m 34s");
});
