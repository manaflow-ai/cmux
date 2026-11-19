// l10n-allow-file: test fixture replies, not shipped UI.
// A turn the agent ran on its own draws its tool calls as normal tool calls, with no "Background
// update" line over them (backgroundTurnLook.experiment.ts `inline`; Leo, 2026-11-11: "it should maybe
// arguably just be treated like a normal tool call"). Its quiet reply still draws nothing.
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

test("a quiet background turn draws its tool call, with no line and no reply", () => {
  const rows = transcript({ quiet: true });
  expect(ids(turnView(rows, new Set()))).toEqual(["prompt", "reply", "summary", "check"]);
  // A fold key left from the line look opens nothing: the reply stays hidden.
  expect(ids(turnView(rows, new Set([backgroundTurnRowId("bg")])))).toEqual(["prompt", "reply", "summary", "check"]);
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
  expect(view).toEqual(["prompt", "reply", "summary", "check", "note", "backgroundEnd-bg"]);
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
  expect(ids(view)).toEqual(["prompt", "reply", "summary", "a-check", "b-check"]);
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
