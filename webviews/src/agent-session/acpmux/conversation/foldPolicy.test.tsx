// l10n-allow-file: test fixtures (commands, thoughts and messages), not shipped UI.
// The fold policy (foldPolicy.ts): which rows fold into one counted line, as a table over row
// descriptors. Leo, 2026-11-12, on 10-20 "Background command completed" rows inside a finished
// turn's "Worked for 4m 44s", between thoughts, "Sent to" rows, "Received 9 messages" and "Subagent
// finished": "how come these aren't folded? they were missed in the logic?" and "this is prob pretty
// obvious as fold candidates... tho ig a 'completed' is technically a more special cased version?"
//
// These run on the default look (backgroundTurnLook.experiment.ts `inline`), where a run of
// background notes drew row by row before.
import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { LANE_NOTICE_BATCH, type AcpmuxActivity, type AcpmuxRow } from "../model";
import { BackgroundTurnLine } from "./BackgroundTurnLine";
import { backgroundRunFoldFor, backgroundRunRowId, foldBackgroundRuns } from "./backgroundRuns";
import { BACKGROUND_TURN } from "./backgroundTurns";
import { foldSpans, RUN_LABELS, runLabelKey, rowRoles, type FoldRole } from "./foldPolicy";
import { WORKED, turnView } from "./turns";
import { SUBAGENT_DONE } from "../subagents/subagentRows";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const note = (id: string, state: "completed" | "failed" | "stopped" = "completed") =>
  row(id, "backgroundTask", { backgroundTask: { toolCallId: `${id}-call`, command: `wait for ${id}`, state } });
const thought = (id: string) =>
  row(id, "activity", { items: [{ kind: "thought", text: "Checking which helper is still running." }] });
const shell = (id: string, command: string, extra: Partial<NonNullable<AcpmuxActivity["tool"]>> = {}) =>
  ({
    kind: "tool",
    text: "Run",
    tool: { id, title: "Bash", kind: "execute", status: "completed", command, ...extra },
  }) as AcpmuxActivity;
const sent = (id: string) =>
  row(id, "activity", { items: [shell(`${id}-call`, "acpmux send fix-chat-flip-loop 'the reorder is fixed'")] });
const ran = (id: string) => row(id, "activity", { items: [shell(`${id}-call`, "git status")] });
const marked = (id: string, state: "completed" | "failed" | "stopped" = "completed") =>
  row(id, "activity", {
    settled: true,
    foldRun: true,
    items: [shell(`${id}-call`, `wt new ${id}`, { background: { state, endedAt: at } })],
  });
const received = (id: string, n: number) =>
  row(id, LANE_NOTICE_BATCH, {
    laneNoticeBatch: {
      kind: "inbox",
      rows: Array.from({ length: n }, (_, i) => row(`${id}-${i}`, "user")),
      verdicts: {},
      threads: [],
    },
  });
const subagentDone = (id: string, state = "done") =>
  row(id, SUBAGENT_DONE, { subagents: [{ id, state, name: "Codex desktop auth" } as never] });
const say = (id: string, text: string) => row(id, "assistant", { text });
const ids = (rows: readonly AcpmuxRow[]) => rows.map((entry) => entry.id);

const M: FoldRole = { role: "member", run: "background", tally: "command" };
const Q: FoldRole = { role: "quiet", sent: 0, received: 0 };
const B: FoldRole = { role: "break" };

test("the span rule over descriptors alone: quiet rows inside a run fold, before and after it they do not", () => {
  expect(foldSpans([Q, M, Q, M, { role: "quiet", sent: 2, received: 1 }, M, Q])).toEqual([
    {
      from: 1,
      to: 6,
      run: "background",
      members: 3,
      tallies: { command: 3, finished: 0, stopped: 0, scheduled: 0, other: 0, sent: 2, received: 1 },
    },
  ]);
  // A break ends a run; one member alone is no run.
  expect(foldSpans([M, B, M, M]).map(({ from, to }) => [from, to])).toEqual([[2, 4]]);
  expect(foldSpans([M, Q, Q, B, M])).toEqual([]);
  // A member's own row extends the run past its last member.
  expect(foldSpans([M, M, { role: "quiet", sent: 0, received: 0, owned: true }, Q])[0]!.to).toBe(3);
});

test("the label table names the run by what its members are", () => {
  const tallies = { command: 0, finished: 0, stopped: 0, scheduled: 0, other: 0, sent: 0, received: 0 };
  expect(runLabelKey("background", { ...tallies, command: 14 }, 14)).toBe("backgroundRun.commandsFinished");
  expect(runLabelKey("background", { ...tallies, command: 2, finished: 2 }, 4)).toBe("backgroundRun.finished");
  expect(runLabelKey("background", { ...tallies, command: 2, stopped: 1 }, 3)).toBe("backgroundRun.updates");
  // The last entry of every run kind always holds, so every run has words.
  for (const entries of Object.values(RUN_LABELS)) expect(entries.at(-1)!.when(tallies, 0)).toBe(true);
});

test("Leo's run: 14 completed background commands between thoughts, sends, received messages and a subagent's end fold into one line", () => {
  at = 0;
  const rows: AcpmuxRow[] = [
    say("before", "Starting the checks."),
    note("c1"),
    thought("t1"),
    sent("s1"),
    note("c2"),
    note("c3"),
    note("c4"),
    note("c5"),
    thought("t2"),
    note("c6"),
    note("c7"),
    note("c8"),
    note("c9"),
    received("r1", 9),
    note("c10"),
    subagentDone("sub1"),
    note("c11"),
    thought("t3"),
    sent("s2"),
    note("c12"),
    note("c13"),
    note("c14"),
    thought("after-thought"),
    say("answer", "The fix needs you, once: sign in again."),
  ];
  const folded = foldBackgroundRuns(rows, new Set());
  const run = backgroundRunRowId("c1");
  expect(ids(folded)).toEqual(["before", run, "after-thought", "answer"]);
  const line = folded[1]!;
  expect(line.kind).toBe(BACKGROUND_TURN);
  expect(line.backgroundRun).toMatchObject({ finished: 14, commands: 14, sent: 2, received: 9 });
  const html = renderToStaticMarkup(<BackgroundTurnLine row={line} expanded={false} onToggle={() => {}} />);
  expect(html).toContain("14 background commands finished, sent 2 messages, received 9 messages");
  expect(html).toContain('data-background-run="commands"');
  // Opened: every row in its place, the quiet ones too.
  const open = foldBackgroundRuns(rows, new Set([run]));
  expect(ids(open)).toEqual(["before", run, ...ids(rows.slice(1, 22)), "after-thought", "answer"]);
  // Find and links open the line for any row it holds.
  expect(backgroundRunFoldFor(folded, "s1")).toBe(run);
  expect(backgroundRunFoldFor(folded, "r1")).toBe(run);
});

test("a failed command stays in sight and splits the run; words for the person end it", () => {
  at = 0;
  const rows = [note("a"), note("b"), note("fail", "failed"), note("c"), say("said", "The build broke."), note("d")];
  expect(ids(foldBackgroundRuns(rows, new Set()))).toEqual([backgroundRunRowId("a"), "fail", "c", "said", "d"]);
});

test("a call that ran is no quiet row: it ends the run", () => {
  at = 0;
  const rows = [note("a"), ran("work"), note("b")];
  expect(foldBackgroundRuns(rows, new Set())).toBe(rows);
});

test("a failed subagent, a fire and a person's message stay in sight", () => {
  at = 0;
  const person = row("person", "user", {
    incoming: { kind: "message", message: { from: "leo", text: "hm?", fromPerson: true } } as never,
  });
  for (const between of [subagentDone("sub", "failed"), person])
    expect(foldBackgroundRuns([note("a"), between, note("b")], new Set()).some((entry) => entry.backgroundRun)).toBe(
      false,
    );
});

test("the call that started a shell, marked completed in a finished turn, is a member too", () => {
  at = 0;
  const rows = [marked("m1"), thought("t"), marked("m2"), note("n3"), marked("m4", "failed")];
  const folded = foldBackgroundRuns(rows, new Set());
  expect(ids(folded)).toEqual([backgroundRunRowId("m1"), "m4"]);
  expect(folded[0]!.backgroundRun).toMatchObject({ commands: 3, finished: 3 });
  // While its turn runs (not settled), a marked call keeps its place.
  const live = rows.map((entry) => ({ ...entry, settled: undefined }));
  expect(ids(foldBackgroundRuns(live, new Set()))).toEqual(ids(live));
});

test("a turn without two members never groups its calls for the policy", () => {
  at = 0;
  const rows = [note("a"), sent("s"), ran("r"), thought("t")];
  // The send between is a break on the cheap pass: no second member, so it is never looked at.
  expect(rowRoles(rows, () => undefined).map((role) => role.role)).toEqual(["member", "break", "break", "quiet"]);
});

test("in a finished Claude turn, the opened Worked for shows the run as one line", () => {
  at = 0;
  const prompt = row("p", "user", { text: "Check the lanes" });
  const rows = [
    prompt,
    ran("w1"),
    note("c1"),
    thought("t1"),
    note("c2"),
    sent("s1"),
    note("c3"),
    say("a", "All three lanes are green."),
    row("s", "turnSummary", { status: "completed", durationMs: 60_000 }),
  ];
  const view = (open: Set<string>) =>
    turnView(rows, open, { now: at + 10_000, agentFamily: "claude" }).filter((entry) => entry.kind !== "user");
  const worked = view(new Set()).find((entry) => entry.kind === WORKED)!;
  const opened = ids(view(new Set([worked.id])));
  const run = backgroundRunRowId("c1");
  expect(opened).toContain(run);
  for (const hidden of ["c1", "t1", "c2", "s1", "c3"]) expect(opened).not.toContain(hidden);
  expect(opened.indexOf(run)).toBeLessThan(opened.indexOf("a"));
});
