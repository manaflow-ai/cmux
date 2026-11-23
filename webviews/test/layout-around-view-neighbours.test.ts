// l10n-allow-file: transcript fixture text.
// A row changed away from the view changes its drawn neighbours too: a footer appended under a reply the reader
// scrolled away from changes the reply's edge, a live line reads the step above it, a row's grid mark reads the row
// above it. The layout that measures only the rows around the view (layoutAroundView) must place every row where the
// whole chat's layout does, or rows overlap or jump until the neighbour mounts (review follow-up on #44389, F1).
import { expect, test } from "bun:test";
import { layoutAroundView, layoutConversation, type AcpmuxRow } from "../src/agent-session/acpmux/model";

const WIDTH = 720;
let serial = 0;
/// One row of a kind the transcript draws, each a fresh object (a changed row is a new object, as the store makes).
const make = (kind: string): AcpmuxRow => {
  serial += 1;
  const base = { id: `${kind}-${serial}`, at: serial, version: 1 };
  switch (kind) {
    case "user":
      return { ...base, kind: "user", text: `Question ${serial}: ${"what does this do ".repeat(1 + (serial % 3))}` };
    case "assistant":
      return { ...base, kind: "assistant", text: `Reply ${serial}. ${"It wraps at this width. ".repeat(serial % 5)}` };
    case "footer":
      return { ...base, kind: "turnSummary", status: "completed", seq: serial, toolCount: serial % 2, text: "Done." };
    case "activity":
      return { ...base, kind: "activity", status: "completed", text: `Ran tool ${serial}` } as AcpmuxRow;
    case "working":
      return { ...base, kind: "working", below: true } as AcpmuxRow;
    default:
      return { ...base, kind: "thinking", below: true } as AcpmuxRow;
  }
};
const KINDS = ["user", "assistant", "footer", "activity", "working", "thinking"];

/// A small seeded generator, so a failure names its case.
function random(seed: number) {
  let state = seed >>> 0 || 1;
  return (below: number) => {
    state ^= state << 13;
    state ^= state >>> 17;
    state ^= state << 5;
    return (state >>> 0) % below;
  };
}

function expectSamePlaces(
  rows: readonly AcpmuxRow[],
  base: readonly AcpmuxRow[],
  view: { from: number; to: number },
  label: string,
) {
  const baseLayout = layoutConversation(base, WIDTH, new Map());
  const around = layoutAroundView(
    rows,
    WIDTH,
    new Map(),
    undefined,
    undefined,
    { rows: base, layout: baseLayout },
    view,
  );
  if (!around) return;
  const whole = layoutConversation(rows, WIDTH, new Map());
  expect({ label, heights: Array.from(around.heights) }).toEqual({ label, heights: Array.from(whole.heights) });
  expect({ label, tops: Array.from(around.tops) }).toEqual({ label, tops: Array.from(whole.tops) });
  expect({ label, total: around.totalHeight }).toEqual({ label, total: whole.totalHeight });
}

test("a footer appended under a reply away from the view places every row as the whole layout does", () => {
  const base: AcpmuxRow[] = [];
  for (let turn = 0; turn < 30; turn += 1) base.push(make("user"), make("assistant"), make("footer"));
  base.push(make("user"), make("activity"), make("assistant"));
  // The reader reads the chat's top; the turn ends at its bottom.
  expectSamePlaces([...base, make("footer")], base, { from: 0, to: 6 }, "footer appended");
});

test("a row changed under a live line's step, away from the view, keeps the live line's gap", () => {
  const base: AcpmuxRow[] = [];
  for (let turn = 0; turn < 30; turn += 1) base.push(make("user"), make("assistant"), make("footer"));
  // A step, the live line under it, then a row that changes: the live line is the measured run's neighbour, and its
  // mark reads the step above it.
  base.push(make("user"), make("activity"), make("working"), make("assistant"));
  const rows = base.slice();
  rows[rows.length - 1] = make("assistant");
  expectSamePlaces(rows, base, { from: 0, to: 6 }, "under a live line");
});

test("random changes and appends away from the view place every row as the whole layout does", () => {
  for (let seed = 1; seed <= 300; seed += 1) {
    const next = random(seed);
    const base: AcpmuxRow[] = [];
    const length = 30 + next(30);
    for (let index = 0; index < length; index += 1) base.push(make(KINDS[next(KINDS.length)]!));
    const rows = base.slice();
    const changes = 1 + next(3);
    for (let change = 0; change < changes; change += 1) rows[next(rows.length)] = make(KINDS[next(KINDS.length)]!);
    const appended = next(3);
    for (let add = 0; add < appended; add += 1) rows.push(make(KINDS[next(KINDS.length)]!));
    const from = next(rows.length - 5);
    expectSamePlaces(rows, base, { from, to: from + 5 }, `seed ${seed}`);
  }
});
