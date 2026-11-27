// The turn view built on the last one (turns.ts `turnViewFrom`, as App.tsx calls it) keeps what did
// not change, at a cost that does not grow with the chat:
// - rule (c) of the chat simulator: a finished turn's rows ("Worked for", footer, plan, activity) stay
//   the same objects when the next prompt comes, or a record goes into the turn after them. A new
//   object with nothing changed lays out, measures and renders again (`steadyRows`).
// - each step shapes only the rows of the turns it changed: the rows it shaped anew (the trace's
//   `shaped`, the view's rows less the `reusedRows` it took over) stay as many on turn 110 as on turn
//   30. Before, every step shaped every turn again (the simulator handed a new fold set each step, so
//   the view never reused one), so a 1,800-turn run took about 86 s.
import { expect, test } from "bun:test";
import { runSimulation, type SimResult } from "../src/agent-session/acpmux/sim/run";
import { longRun } from "../src/agent-session/acpmux/sim/scenarios";

const TURNS = 120;
let run: SimResult | undefined;
const result = () => (run ??= runSimulation(longRun(TURNS), { rowsInTraceUpTo: 0 }));

test(`a ${TURNS}-turn chat rebuilds no row two or more turns back (rule c)`, () => {
  const rebuilt = result()
    .violations.filter((violation) => violation.rule === "c-rerender")
    .map((violation) => `step ${violation.step} (${violation.label}): ${violation.rowId}`);
  expect(rebuilt).toEqual([]);
}, 120_000);

test("a step shapes as many rows late in a long chat as early in it", () => {
  const { traces } = result();
  // The most rows any step shaped anew, over the steps of turns `from` up to `to`.
  const most = (from: number, to: number) =>
    Math.max(...traces.filter((trace) => trace.turn >= from && trace.turn < to).map((trace) => trace.shaped));
  const early = most(20, 40);
  const late = most(100, TURNS);
  // A long chat: about four rows a turn, since a closed turn keeps only its final answer in sight.
  expect(traces.at(-1)!.rowCount).toBeGreaterThan(400);
  // A step reshapes its own turn and the one before it (a dozen rows each here), never the chat.
  expect(late).toBeLessThan(60);
  expect(late).toBeLessThanOrEqual(early + 10);
}, 120_000);
