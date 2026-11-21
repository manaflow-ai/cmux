// l10n-allow-file: transcript test fixtures.
import { expect, test } from "bun:test";
import { isEditCard, type AcpmuxActivity, type AcpmuxRow } from "../model";
import { sessionEdits } from "../turnChanges/sessionRows";
import { rowKind } from "../virtualTranscriptModel";
import { tamperingForRows } from "./testTamperingModel";
import { isTestTamperingTurn, TEST_TAMPERING_TURN, testTamperingTurn } from "./testTamperingTurn";
import { turnView, turnViewFrom } from "./turns";

const prompt = (id = "prompt-1", turnId = "turn-1"): AcpmuxRow => ({
  id,
  turnId,
  kind: "user",
  version: 1,
  at: 1_000,
  text: "Fix the failing tests",
});
const edit = (id = "edit-1", path = "src/example.test.ts"): AcpmuxActivity => ({
  kind: "tool",
  text: "Edit test",
  tool: {
    id,
    title: "Edit test",
    kind: "edit",
    status: "completed",
    diffs: [{ path, oldText: "expect(value).toEqual(1)", newText: "expect(value).toBeTruthy()" }],
    tamperingEventSeq: 42,
    tampering: {
      count: 1,
      files: [
        {
          path,
          findings: [
            {
              kind: "weakened_assertion",
              line: 3,
              message: "Exact assertion became a truthiness check",
              old: "expect(value).toEqual(1)",
              new: "expect(value).toBeTruthy()",
            },
          ],
        },
      ],
    },
  },
});
const activity = (id: string, items: AcpmuxActivity[], fields: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind: "activity",
  version: 1,
  at: 2_000,
  seq: 42,
  turnId: "turn-1",
  items,
  ...fields,
});
const summary: AcpmuxRow = {
  id: "summary",
  kind: "turnSummary",
  version: 1,
  at: 4_000,
  status: "completed",
  durationMs: 3_000,
};
const options = { now: 10_000, working: true, agentFamily: "codex" };
const alarms = (rows: readonly AcpmuxRow[]) => rows.filter(isTestTamperingTurn);

test("the first edit alarms live; two flagged edits share one row outside the tool fold", () => {
  const user = prompt();
  const first = edit();
  first.tool!.status = "in_progress";
  const firstRow = activity("activity-1", [first]);
  const live = turnView([user, firstRow], new Set(), options);
  const alarm = alarms(live)[0]!;
  expect(alarms(live)).toHaveLength(1);
  expect(live.indexOf(alarm)).toBe(live.indexOf(user) + 1);
  expect(isEditCard(alarm)).toBe(false);
  expect(rowKind(alarm)).toBe(TEST_TAMPERING_TURN);
  expect(sessionEdits([firstRow, alarm]).edits).toEqual([firstRow]);
  expect(alarm.items).toEqual([first]);

  const ordinary = edit("ordinary");
  delete ordinary.tool!.tampering;
  const second = edit("edit-2", "tests/another.test.ts");
  const next = turnView(
    [
      user,
      firstRow,
      activity("activity-2", [
        { kind: "thought", text: "Check the result" },
        {
          kind: "tool",
          text: "Run tests",
          tool: { id: "run", title: "Run tests", kind: "execute", status: "completed" },
        },
        ordinary,
        second,
      ]),
    ],
    new Set(),
    options,
  );
  expect(alarms(next)).toHaveLength(1);
  expect(alarms(next)[0]!.id).toBe(alarm.id);
  expect(alarms(next)[0]!.items).toEqual([first, second]);
  expect(tamperingForRows(alarms(next))).toHaveLength(2);
});

test("completion and worked disclosure toggles retain the live alarm identity and evidence", () => {
  const user = prompt();
  const tool = edit();
  const source = [user, activity("activity", [tool])];
  const live = alarms(turnView(source, new Set(), options))[0]!;
  for (const folds of [new Set<string>(), new Set([`worked-${user.id}`])]) {
    const ended = turnView([...source, summary], folds, { ...options, working: false });
    expect(alarms(ended)).toHaveLength(1);
    expect(alarms(ended)[0]).toBe(live);
    expect(ended.indexOf(live)).toBe(ended.indexOf(user) + 1);
    expect(live.items![0]).toBe(tool);
    expect(live.items![0]!.tool!.tamperingEventSeq).toBe(42);
  }
});

test("separate turns keep separate alarms even when a replay reuses a tool id and finding", () => {
  const shown = turnView(
    [
      prompt(),
      activity("activity-1", [edit()]),
      summary,
      prompt("prompt-2", "turn-2"),
      activity("activity-2", [edit()], { at: 5_000, turnId: "turn-2" }),
    ],
    new Set(),
    options,
  );
  expect(alarms(shown).map((row) => row.turnId)).toEqual(["turn-1", "turn-2"]);
  expect(new Set(alarms(shown).map((row) => row.id)).size).toBe(2);
});

test("streamed prose and an unrelated tool preserve the alarm row and its version", () => {
  const user = prompt();
  const row = activity("activity", [edit()]);
  const alarm = testTamperingTurn(user, [row])!;
  const answer: AcpmuxRow = {
    id: "answer",
    kind: "assistant",
    version: 1,
    at: 3_000,
    text: "Checking",
  };
  expect(testTamperingTurn(user, [row, answer])).toBe(alarm);
  expect(testTamperingTurn(user, [row, { ...answer, version: 2, text: "Checking again" }])).toBe(alarm);
  const read = activity("read", [
    {
      kind: "tool",
      text: "Read",
      tool: { id: "read", title: "Read", kind: "read", status: "completed" },
    },
  ]);
  expect(testTamperingTurn(user, [row, read])).toBe(alarm);
});

test("a replay uses the latest successful edit and keeps exact restore metadata", () => {
  const user = prompt();
  const old = edit();
  const updated = { ...old, tool: { ...old.tool!, tamperingEventSeq: 84 } };
  const earlier = activity("early", [old]);
  const latest = activity("latest", [updated], { seq: 84 });
  const alarm = testTamperingTurn(user, [earlier, latest])!;
  expect(alarm.items).toHaveLength(1);
  expect(alarm.items![0]).toBe(updated);
  expect(alarm.items![0]!.tool).toBe(updated.tool);
  expect(alarm.seq).toBe(84);
  expect(alarm.turnId).toBe(user.turnId);
  const failed = { ...updated, tool: { ...updated.tool, status: "failed" } };
  expect(testTamperingTurn(user, [earlier, latest, activity("failure", [failed])])).toBeUndefined();
  expect(testTamperingTurn(user, [activity("row-failure", [updated], { failed: true })])).toBeUndefined();
});

test("pending, empty, unrelated and ordinary edit reports cannot create an alarm", () => {
  const pending = edit();
  pending.tool!.status = "pending";
  const empty = edit("empty");
  empty.tool!.tampering = { count: 1, files: [] };
  const ordinary = edit("ordinary");
  delete ordinary.tool!.tampering;
  const unrelated = edit("unrelated");
  unrelated.tool!.kind = "execute";
  expect(testTamperingTurn(prompt(), [activity("activity", [pending, empty, ordinary, unrelated])])).toBeUndefined();
});

test("incremental shaping reuses the earlier turn's alarm as the latest turn changes", () => {
  const folds = new Set<string>();
  const source = [
    prompt(),
    activity("activity-1", [edit()]),
    summary,
    prompt("prompt-2", "turn-2"),
    activity("activity-2", [edit("edit-2")], { turnId: "turn-2" }),
  ];
  const previous = turnViewFrom(source, folds, options);
  const next = turnViewFrom(
    [...source, { id: "answer", kind: "assistant", version: 1, at: 7_000, text: "Checking" }],
    folds,
    options,
    previous,
  );
  expect(alarms(next.rows)).toHaveLength(2);
  expect(alarms(next.rows)[0]).toBe(alarms(previous.rows)[0]);
  expect(alarms(next.rows)[1]).toBe(alarms(previous.rows)[1]);
});

test("replacing the prompt object cannot reuse a stale memo version", () => {
  const user = prompt();
  const first = testTamperingTurn(user, [activity("activity", [edit()])])!;
  const changed = edit();
  changed.tool!.tamperingEventSeq = 84;
  const second = testTamperingTurn({ ...user, version: 2 }, [activity("activity", [changed])])!;
  expect(second.id).toBe(first.id);
  expect(second.version).not.toBe(first.version);
});
