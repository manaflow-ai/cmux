// Leo, 2026-11-22 21:37Z: "and then when i sent that message it was as if briefliy the worked for disappeared and
// then reappeared and we just had this crazy flicker where it forgot it just folded and settled and then it acted
// as if the turn was still going so clearly the lifecycle gets fucked but accounting for space for the worked
// for/working heading should always be there anyways so it disappearing means there's multiple problems".
//
// After a turn settles under its "Worked for", a prompt sent must not make the settled turn's heading vanish or
// open again, and the new turn's heading stands in its place from the turn's first row to its end.
import { describe, expect, test } from "bun:test";
import { churnSummary, runSimulation } from "../src/agent-session/acpmux/sim/run";
import { SCENARIOS } from "../src/agent-session/acpmux/sim/scenarios";

for (const name of ["churn", "send-after-settle"]) {
  describe(`worked-for keeps its space: ${name}`, () => {
    const result = runSimulation(SCENARIOS[name]!());
    const traces = result.traces.filter((trace) => trace.rows);
    const sendAt = traces.findIndex((trace) => trace.label.startsWith("prompt:") && trace.turn === 2);
    console.log(churnSummary(result));

    test("no Worked for or Working for heading flashes", () => {
      expect(result.flashes.filter((flash) => flash.kind === "worked" || flash.kind === "working")).toEqual([]);
    });

    test("the settled turn's Worked for stays, closed, at every step after the send", () => {
      expect(sendAt).toBeGreaterThan(0);
      const settled = traces[sendAt - 1]!.rows!.filter((row) => row.kind === "worked").map((row) => row.id);
      expect(settled.length).toBeGreaterThan(0);
      for (const trace of traces.slice(sendAt)) {
        const now = trace.rows!.filter((row) => row.kind === "worked" && settled.includes(row.id));
        expect({
          label: trace.label,
          worked: now.map((row) => `${row.id}:${row.fold}`),
        }).toEqual({
          label: trace.label,
          worked: settled.map((id) => `${id}:closed`),
        });
      }
    });

    // From the step acpmux says the turn runs: the prompt's own record comes 300 ms before `status running`,
    // with no turn yet to head.
    test("the new turn's heading stands from the turn's first row to its end, never gone in between", () => {
      const prompt = traces[sendAt]!.rows!.filter((row) => row.kind === "user").at(-1)!;
      const heading = (rows: NonNullable<(typeof traces)[number]["rows"]>) =>
        rows.some((row) => (row.kind === "working" || row.kind === "worked") && row.id.endsWith(prompt.id));
      const running = traces.findIndex((trace, at) => at > sendAt && trace.working);
      const gone = traces
        .slice(running)
        .filter((trace) => !heading(trace.rows!))
        .map((trace) => trace.label);
      expect(gone).toEqual([]);
    });

    test("no shift of drawn rows after the send", () => {
      const at = traces[sendAt]!.t;
      expect(result.shifts.filter((shift) => shift.at >= at)).toEqual([]);
    });
  });
}
