// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A fold never reorders the transcript (Leo, 2026-11-11: "Why is it a top-level fold, though? Why
// should it be that way? ... sometimes it just gets super duper awkward because it sort of, like,
// steals commands that came in, perhaps, like, in between something, and it just shunts them to the
// top, like it rewrites the transcript in a way"). Each run of agent work between two rows that stay in
// sight folds under its own "Worked for" where it ran; the person's messages and the agent's text
// answers stay where they happened. A steer mid-turn means two folds, one on each side of it. Every
// agent-activity row is work, the turns a notification woke included ("why [aren't] these getting
// folded? Background command completed. Do those not count as the works for?"): a notification turn
// with no text answer folds to one row.
import { afterEach, expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnFoldFor, turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";
import { BACKGROUND_TURN } from "../src/agent-session/acpmux/conversation/backgroundTurns";
import { SUBAGENT_DONE } from "../src/agent-session/acpmux/subagents/subagentRows";

const START = Date.UTC(2026, 10, 11, 21, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const calls = (id: string, second: number, count: number): AcpmuxRow =>
  row(id, "activity", second, {
    toolCount: count,
    items: Array.from({ length: count }, (_, index): AcpmuxActivity => ({
      kind: "tool",
      text: "",
      tool: {
        id: `${id}-${index}`,
        title: `gh pr checks ${index}`,
        kind: "execute",
        status: "completed",
        command: `gh pr checks ${index}`,
      },
    })),
  });
const answer = (id: string, second: number, text: string) => row(id, "assistant", second, { text });
const LONG =
  "The fold fix is up for review.\n\n- Each run of work folds where it ran.\n- Your steer stays where you sent it.";

/// A turn the person steered mid-turn: work, his steer, more work, the answer.
const steered: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Land the fold fix" }),
  calls("t-1", 1, 3),
  row("s-1", "user", 20, { text: "Also check the nightly", steer: "landed" }),
  calls("t-2", 21, 2),
  answer("a-final", 40, LONG),
  row("sum-0", "turnSummary", 41, { status: "completed", durationMs: 41_000, toolCount: 5 }),
];

/// A finished turn, then a turn a background task's end woke with no prompt: a background command's
/// end, a subagent's end and its report, the calls it ran, nothing said. Then another that answered.
const woken: AcpmuxRow[] = [
  row("u-1", "user", 0, { text: "Open the PR" }),
  calls("t-3", 1, 2),
  answer("a-1", 10, LONG),
  row("sum-1", "turnSummary", 11, { status: "completed", durationMs: 11_000, toolCount: 2 }),
  row("bg-1", "backgroundTask", 30, {
    backgroundTask: { toolCallId: "c-9", command: "wt new cmux fix", state: "completed" },
  }),
  row(`${SUBAGENT_DONE}:helper`, SUBAGENT_DONE, 31, {
    subagents: [{ id: "helper", name: "Show-more hit area", state: "completed", startedAt: START } as never],
  }),
  row("bg-2", "backgroundTask", 32, {
    backgroundTask: { toolCallId: "c-8", command: "bun test", state: "stopped" },
  }),
  calls("t-4", 33, 1),
  row("sum-2", "turnSummary", 34, { status: "completed" }),
  row("bg-3", "backgroundTask", 50, {
    backgroundTask: { toolCallId: "c-7", command: "gh pr merge", state: "completed" },
  }),
  answer("a-2", 52, LONG),
];

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

const FAMILIES = ["claude", "codex", undefined];
const view = (rows: AcpmuxRow[], family: string | undefined, open: string[] = []) =>
  turnView(rows, new Set(open), { agentFamily: family, now: START + 100_000 });
/// The drawn rows that stand for something in the source: a fold by "W", a row by its id.
const outline = (rows: AcpmuxRow[]) =>
  rows.flatMap((shown) =>
    shown.kind === WORKED ? ["W"] : shown.kind === "turnSummary" || shown.kind === "date" ? [] : [shown.id],
  );
/// Each source row's place in `rows` as drawn, or where the fold that holds it is drawn.
const places = (source: AcpmuxRow[], drawn: AcpmuxRow[]) => {
  const at = new Map(drawn.map((shown, index) => [shown.id, index]));
  return source
    .filter((r) => r.kind !== "turnSummary")
    .map((r) => {
      if (at.has(r.id)) return at.get(r.id)!;
      const fold = turnFoldFor(source, source.indexOf(r));
      const index = drawn.findIndex(
        (shown) => shown.kind === WORKED && fold !== undefined && shown.id.startsWith(fold),
      );
      return index;
    });
};

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: a steer mid-turn stays where it was sent, with a fold on each side`, () => {
    const closed = view(steered, family);
    expect(outline(closed)).toEqual(["u-0", "W", "s-1", "W", "a-final"]);
    // Opened, the same order, every call in its place between the same rows.
    const open = view(steered, family, [`${WORKED}-u-0`]);
    expect(outline(open)).toEqual(["u-0", "W", "t-1", "s-1", "W", "t-2", "a-final"]);
    // Nothing is drawn before a row that came before it.
    const drawn = places(steered, open);
    expect(drawn).toEqual([...drawn].sort((a, b) => a - b));
    // Each fold times its own stretch.
    const folds = closed.filter((shown) => shown.kind === WORKED);
    expect(folds.map((fold) => fold.durationMs)).toEqual([20_000, 20_000]);
  });

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: a turn a notification woke folds its work in place`, () => {
    const closed = view(woken, family);
    // The first turn's work and its answer, then everything the agent did on its own after it, up to
    // its next words, as one fold where it ran: the woken turn that said nothing, and the next one's
    // command before its answer.
    expect(outline(closed)).toEqual(["u-1", "W", "a-1", "W", "a-2"]);
    for (const id of ["bg-1", "bg-2", `${SUBAGENT_DONE}:helper`, "t-4", "bg-3"])
      expect(closed.some((shown) => shown.id === id)).toBe(false);
    // Each tail fold opens on its own, in place.
    const tail = closed.filter((shown) => shown.kind === WORKED)[1]!;
    const opened = view(woken, family, [tail.id]);
    expect(outline(opened)).toEqual([
      "u-1",
      "W",
      "a-1",
      "W",
      "bg-1",
      `${SUBAGENT_DONE}:helper`,
      "bg-2",
      "t-4",
      "bg-3",
      "a-2",
    ]);
    // Find opens the fold that holds a woken turn's row.
    expect(
      turnFoldFor(
        woken,
        woken.findIndex((r) => r.id === "bg-2"),
      ),
    ).toBe(tail.id);
  });

test("a notification-started turn with no text answer folds entirely into one row", () => {
  const notice: AcpmuxRow[] = [
    row("u-2", "user", 0, { text: "Ship it" }),
    answer("a-3", 2, LONG),
    row("sum-3", "turnSummary", 3, { status: "completed" }),
    row("n-1", "user", 30, {
      text: "Background command completed",
      incoming: { kind: "notice", text: "Background command completed" },
    } as Partial<AcpmuxRow>),
    calls("t-5", 31, 2),
    row("bt-1", BACKGROUND_TURN, 32, {}),
    row("sum-4", "turnSummary", 33, { status: "completed", toolCount: 2 }),
  ];
  for (const family of ["claude", "codex"]) {
    const drawn = view(notice, family);
    expect(outline(drawn)).toEqual(["u-2", "a-3", "W"]);
  }
});
