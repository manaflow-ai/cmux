// l10n-allow-file: test fixture text, not shipped UI.
// A turn's end moves nothing that was already on screen. Leo, 2026-11-22, with a recording of his own
// chat: "IT FUCKING JUMPS ... WHEN A TURN BY AN AGENT END / STOP ADDING FUCKING DINGLEBERRIES OF TOOL
// CALLS AND BULLSHIT THAT SHIFTS POORLY. IF IT NEEDS TO SHIFT, IT SHIFTS MOTHERFUCKING GRACEFULLY.
// THAT'S TEH GOAL. / AND I SHOULDN'T HAVE TO KEEP FUCKING IDENTIFYING THIS SHIT".
//
// The rows only an ended turn used to draw — its edits card, its walkthrough, its tagged next-step
// card, its task lines — were appended at the live→ended swap at their full measured height, with no
// space kept for them. The reader's bottom is pinned, so every row above the append rose by its
// height; a reader scrolled up was pushed down by the same amount. `shapeTurn` already had the cure
// for the families that mark a final answer: the provisional-summary path (turns.ts) shapes the ended
// tail while the turn is still live. These tests pin the three parts of closing it:
//   1. the ended turn draws no row the live turn had not already drawn (nothing arrives at the swap);
//   2. the end adds no height, so a pinned bottom lifts nothing;
//   3. every row the live turn drew keeps its exact top, mid-transcript included.
// Measured on this fixture, one harness, before and after: the ended turn used to end 37.75px lower
// than the live turn it replaces (its tagged ask card, appended); it now ends in the same place, and
// the card is drawn live. Note 3 holds on either side here -- `layoutConversation` lays rows from the
// top, so an append at the bottom moves no top -- which is why 1 and 2 are the gates.
import { expect, test } from "bun:test";
import { layoutConversation, type AcpmuxRow } from "../model";
import { turnView } from "./turns";

const row = (id: string, kind: string, at: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at,
  ...extra,
});

const call = (id: string, title: string, command: string): AcpmuxRow =>
  row(id, "activity", 0, {
    items: [{ kind: "tool", text: title, tool: { id, kind: "execute", title, command, status: "completed" } }],
  });

/// A reply that ends on a tagged ask, which only an ended turn used to draw as a card.
const ASK = [
  "Landed the fix and the gate is green.",
  "",
  "- **[taste]** Should the fold keep the old look?",
  "  - Keep it",
  "  - Use the new one",
].join("\n");

/// An earlier turn, so there are rows above the ending one whose tops must not move.
const earlier = [
  row("p0", "user", 0, { text: "Start the work" }),
  call("c0", "git status", "git status"),
  row("a0", "assistant", 2_000, { text: "Started." }),
  row("s0", "turnSummary", 3_000, { status: "completed", durationMs: 3_000 }),
];

/// The turn that ends: its work, then a reply marked `final_answer`, which is the moment its
/// conclusion becomes knowable (`isFinalAnswer`).
const ending = [
  row("p1", "user", 10_000, { text: "Now fix the jump" }),
  call("c1", "sed -n", "sed -n '1,20p' turns.ts"),
  call("c2", "apply patch", "apply_patch"),
  row("a1", "assistant", 20_000, { text: ASK, assistantPhase: "final_answer" }),
];

const summary = row("s1", "turnSummary", 21_000, { status: "completed", durationMs: 11_000, turnId: "t1" });

/// Every row's top by its id, so rows that only one side draws are compared on the ids they share.
const topsById = (rows: readonly AcpmuxRow[]): Map<string, number> => {
  const layout = layoutConversation([...rows], 720);
  return new Map(rows.map((each, index) => [each.id, layout.tops[index]!]));
};

const bottom = (rows: readonly AcpmuxRow[]): number => {
  const layout = layoutConversation([...rows], 720);
  return layout.totalHeight + (layout.tailGap ?? 0) + (layout.restBand ?? 0);
};

// Codex and ChatGPT mark a final answer (turnFoldStyle.ts `conclusion`), so the concluding
// projection runs for them and the conclusion's own rows are already in place before `turn_result`.
for (const agentFamily of ["codex", "claude"])
  test(`${agentFamily}: a turn's end draws nothing the live turn had not drawn, and moves no row`, () => {
    const options = { now: 60_000, agentFamily };
    const live = turnView([...earlier, ...ending], new Set(), { ...options, working: true });
    const done = turnView([...earlier, ...ending, summary], new Set(), { ...options, working: false });
    const before = topsById(live);
    const after = topsById(done);

    // The fixture is only worth something if both sides really drew the rows above and inside the turn.
    expect(before.size).toBeGreaterThan(4);
    const shared = [...before.keys()].filter((id) => after.has(id));
    expect(shared.length).toBeGreaterThan(3);

    // Nothing arrives at the swap. The ended turn's rows are the live turn's, except its own summary
    // row, which takes the live line's slot (liveLineTakesFooterSlot.test.ts). Before the fix the
    // tagged ask card was in `done` and not in `live`, and this is the assertion that caught it.
    const arrived = [...after.keys()].filter((id) => !before.has(id) && id !== summary.id);
    expect(arrived).toEqual([]);

    const moved = shared
      .map((id) => ({ id, was: before.get(id)!, now: after.get(id)!, by: after.get(id)! - before.get(id)! }))
      .filter((each) => Math.abs(each.by) > 0.5);
    expect(moved).toEqual([]);
  });

// A row appended below the reader is the push itself: if the end adds height under the rows that were
// already drawn, a pinned bottom lifts every one of them (`anchorPass` pins one row, and nothing
// below it may change height) and a reader scrolled up is shoved down by the same amount.
test("a turn's end adds no height under the rows that were already drawn", () => {
  const options = { now: 60_000, agentFamily: "codex" };
  const live = turnView([...earlier, ...ending], new Set(), { ...options, working: true });
  const done = turnView([...earlier, ...ending, summary], new Set(), { ...options, working: false });
  // The live line's slot is the footer's, so the two ends agree to within layout rounding.
  expect(Math.abs(bottom(done) - bottom(live))).toBeLessThanOrEqual(0.5);
});

// A turn that only ran bookkeeping ends on a footer of hover controls (turns.ts `isEmptyFooter`),
// which lays over the gap and takes no height of its own (model.ts `isOverlayFooter`). Its work folds
// away as the turn ends, and that fold is the one motion `turn-end` declares -- it is the graceful
// shift Leo asked for, not a jump -- so what is pinned here is that the fold is all of it: the rows
// above it do not move.
test("a bookkeeping turn's end moves nothing above its fold", () => {
  const quiet = [
    row("p2", "user", 0, { text: "Earlier, and it stays put" }),
    row("a2", "assistant", 1_000, { text: "Noted." }),
    row("s3", "turnSummary", 2_000, { status: "completed", durationMs: 2_000 }),
    row("p3", "user", 10_000, { text: "Just bookkeeping" }),
    call("c3", "git log", "git log -1"),
  ];
  const options = { now: 60_000, agentFamily: "codex" };
  const live = turnView(quiet, new Set(), { ...options, working: true });
  const done = turnView(
    [...quiet, row("s2", "turnSummary", 14_000, { status: "completed", durationMs: 4_000 })],
    new Set(),
    {
      ...options,
      working: false,
    },
  );
  expect(live.at(-1)!.below).toBe(true);
  expect(done.at(-1)!.kind).toBe("turnSummary");
  const before = topsById(live);
  const after = topsById(done);
  for (const id of ["p2", "a2", "s3", "p3"]) {
    expect(after.has(id)).toBe(true);
    expect(Math.abs(after.get(id)! - before.get(id)!)).toBeLessThanOrEqual(0.5);
  }
});
