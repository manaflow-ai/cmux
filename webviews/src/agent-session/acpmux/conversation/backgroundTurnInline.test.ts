// l10n-allow-file: test fixture replies, not shipped UI.
// A turn the agent ran on its own draws its tool calls as normal tool calls, with no "Background
// update" line over them (backgroundTurnLook.experiment.ts `inline`; Leo, 2026-11-11: "it should maybe
// arguably just be treated like a normal tool call"). Its quiet reply still draws nothing. Once it ends,
// its calls fold under one "Worked for", as a prompt's turn's do (cmux#49592).
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { BACKGROUND_RUN } from "./backgroundRuns";
import { turnView } from "./turns";

beforeEach(() => {
  globalThis.cmuxExperiments = { "background-turn-look": "inline" };
});
afterEach(() => {
  delete globalThis.cmuxExperiments;
});

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const line = (id: string, background: Partial<NonNullable<AcpmuxRow["background"]>>) =>
  row(backgroundTurnRowId(id), BACKGROUND_TURN, {
    background: { id, trigger: "system", running: false, hasRows: true, ...background },
  });
const call = (id: string, inBackground: string) =>
  row(id, "activity", {
    inBackground,
    items: [{ kind: "tool", text: "Ran check", tool: { id, title: "check", kind: "execute", status: "completed" } }],
  });

const transcript = (background: Partial<NonNullable<AcpmuxRow["background"]>>) => {
  at = 0;
  return [
    row("prompt", "user", { text: "Run the suite" }),
    row("reply", "assistant", { text: "Started it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("bg", background),
    call("check", "bg"),
    row("note", "assistant", { text: "Nothing new for you yet.", inBackground: "bg" }),
  ];
};
const ids = (rows: AcpmuxRow[]) => rows.filter((entry) => entry.kind !== "date").map((entry) => entry.id);

// It ends on its row of actions, as every ended turn does (turnEndActions.experiment.ts; Leo,
// 2026-11-21: "there's no buttons at the bottom even thuogh you have visibly stopped doing things").
test("a quiet background turn draws its tool call and its row, with no line and no reply", () => {
  const rows = transcript({ quiet: true });
  const drawn = ["prompt", "reply", "summary", "worked-backgroundTurn-bg", "backgroundEnd-bg"];
  expect(ids(turnView(rows, new Set()))).toEqual(drawn);
  // A fold key left from the line look opens nothing: the reply stays hidden.
  expect(ids(turnView(rows, new Set([backgroundTurnRowId("bg")])))).toEqual(drawn);
});

// Leo, 2026-11-25: "this is extremely strange": a quiet turn of one thought and two sentences drew
// its "Worked for" over the thought and hid its answer. Its answer draws under its Worked for.
test("a quiet background turn whose only work is a thought draws its reply under its Worked for", () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Run the suite" }),
    row("reply", "assistant", { text: "Started it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("bg", { quiet: true }),
    row("thought", "activity", {
      inBackground: "bg",
      items: [
        { kind: "thought", text: "Already known: the run passed and the PR merged.", startedAt: 0, endedAt: 3_000 },
      ],
    }),
    row("note", "assistant", { text: "The suite passed and the PR merged.", inBackground: "bg" }),
  ];
  const view = ids(turnView(rows, new Set()));
  expect(view).toContain("note");
  expect(view.indexOf("note")).toBeGreaterThan(view.indexOf("worked-backgroundTurn-bg"));
});

test("a running background turn draws its calls as they come, its reply not yet", () => {
  const view = ids(turnView(transcript({ running: true }), new Set()));
  expect(view).toEqual(["prompt", "reply", "summary", "check"]);
});

test("a silent turn no call took that ended with something to say draws its reply", () => {
  const rows = transcript({
    quiet: false,
    trigger: "task_notification",
    cause: { kind: "monitor", status: "event", weight: "silent" },
  });
  expect(ids(turnView(rows, new Set()))).toContain("note");
});

test("a background turn with something to say draws as before", () => {
  const view = ids(turnView(transcript({ quiet: false }), new Set()));
  expect(view).toEqual(["prompt", "reply", "summary", "worked-backgroundTurn-bg", "note", "backgroundEnd-bg"]);
});

test('quiet background turns in a row draw no "N background updates" line', () => {
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Run the suite" }),
    row("reply", "assistant", { text: "Started it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("a", { quiet: true, trigger: "scheduled" }),
    call("a-check", "a"),
    line("b", { quiet: true }),
    call("b-check", "b"),
  ];
  const view = turnView(rows, new Set());
  expect(view.some((entry) => entry.kind === BACKGROUND_TURN || entry.id.startsWith(BACKGROUND_RUN))).toBe(false);
  // Each ends on its own row, as a prompt's turn does.
  expect(ids(view)).toEqual([
    "prompt",
    "reply",
    "summary",
    "worked-backgroundTurn-a",
    "backgroundEnd-a",
    "worked-backgroundTurn-b",
    "backgroundEnd-b",
  ]);
});

test("in the `last` arm only the chat's last quiet turn ends on its row", () => {
  globalThis.cmuxExperiments = { "background-turn-look": "inline", "turn-end-actions": "last" };
  at = 0;
  const rows = [
    row("prompt", "user", { text: "Run the suite" }),
    row("reply", "assistant", { text: "Started it." }),
    row("summary", "turnSummary", { status: "completed", durationMs: 2_000 }),
    line("a", { quiet: true, trigger: "scheduled" }),
    call("a-check", "a"),
    line("b", { quiet: true }),
    call("b-check", "b"),
  ];
  expect(ids(turnView(rows, new Set()))).toEqual([
    "prompt",
    "reply",
    "summary",
    "worked-backgroundTurn-a",
    "worked-backgroundTurn-b",
    "backgroundEnd-b",
  ]);
  globalThis.cmuxExperiments = { "background-turn-look": "inline", "turn-end-actions": "off" };
  // Fresh rows: a turn's shape is cached by its rows, and the arm is no part of that key.
  const fresh = rows.map((each) => ({ ...each }));
  expect(ids(turnView(fresh, new Set()))).toEqual([
    "prompt",
    "reply",
    "summary",
    "worked-backgroundTurn-a",
    "worked-backgroundTurn-b",
  ]);
});

test("the line look still folds a quiet turn to its line", () => {
  globalThis.cmuxExperiments = { "background-turn-look": "line" };
  expect(ids(turnView(transcript({ quiet: true }), new Set()))).toEqual([
    "prompt",
    "reply",
    "summary",
    backgroundTurnRowId("bg"),
  ]);
});
