import { describe, expect, test } from "bun:test";
import { type ActionMeasure, type StateReport, judgeAction, judgeFeel, onePerState, stableFindings, waves } from "./feel";

const measure = (partial: Partial<ActionMeasure>): ActionMeasure => ({
  action: "click",
  target: 'button "Open"',
  changes: [],
  shifts: [],
  longFrames: [],
  settleMs: 300,
  capped: false,
  ...partial,
});

describe("feel judges", () => {
  test("a click that changes nothing is dead", () => {
    const report = judgeAction(measure({}));
    expect(report.responseMs).toBeNull();
    expect(report.findings.map((f) => f.kind)).toEqual(["dead-click"]);
  });

  test("a hover that changes nothing is fine", () => {
    expect(judgeAction(measure({ action: "hover" })).findings).toEqual([]);
  });

  test("a focus move alone is a response", () => {
    const report = judgeAction(measure({ changes: [{ t: 8, kind: "focus" }] }));
    expect(report.responseMs).toBe(8);
    expect(report.findings).toEqual([]);
  });

  test("a response over the limit is slow, with its number", () => {
    const report = judgeAction(measure({ changes: [{ t: 340, kind: "add", label: "div.menu", area: 4000 }] }));
    expect(report.findings.map((f) => f.kind)).toEqual(["slow-response"]);
    expect(report.findings[0]!.detail).toContain("340 ms");
  });

  test("content in a later wave is pop-in; one wave is not", () => {
    const one = judgeAction(measure({ changes: [{ t: 10, kind: "add", area: 5000 }, { t: 40, kind: "add", area: 5000 }] }));
    expect(one.findings).toEqual([]);
    expect(one.waves).toBe(1);
    const late = judgeAction(measure({ changes: [{ t: 10, kind: "add", label: "div.spinner", area: 400 }, { t: 260, kind: "add", label: "ul.rows", area: 9000 }] }));
    expect(late.findings.map((f) => f.kind)).toEqual(["pop-in"]);
    expect(late.findings[0]!.detail).toContain("ul.rows appeared 250 ms");
  });

  test("a caret-sized late node is not pop-in", () => {
    const report = judgeAction(measure({ changes: [{ t: 10, kind: "attr" }, { t: 500, kind: "add", area: 20 }] }));
    expect(report.findings).toEqual([]);
  });

  test("a shift in the first wave is the action's own; a later one is a jump", () => {
    const own = judgeAction(measure({ changes: [{ t: 10, kind: "add", area: 5000 }], shifts: [{ t: 16, value: 0.05, sources: ["div.list"] }] }));
    expect(own.findings).toEqual([]);
    const jump = judgeAction(measure({ changes: [{ t: 10, kind: "add", area: 5000 }, { t: 400, kind: "attr" }], shifts: [{ t: 400, value: 0.02, sources: ["div.footer"] }] }));
    expect(jump.findings.map((f) => f.kind)).toEqual(["layout-jump"]);
    expect(jump.lateShift).toBe(0.02);
  });

  test("hovering never moves layout", () => {
    const report = judgeAction(measure({ action: "hover", changes: [{ t: 5, kind: "attr" }], shifts: [{ t: 6, value: 0.004, sources: ["div.row"] }] }));
    expect(report.findings.map((f) => f.kind)).toEqual(["hover-shift"]);
  });

  test("an action that never settles is not judged for waves", () => {
    const report = judgeAction(measure({ capped: true, changes: [{ t: 10, kind: "attr" }, { t: 600, kind: "add", area: 9000 }] }));
    expect(report.findings).toEqual([]);
  });

  test("waves split on gaps over 50 ms", () => {
    expect(waves([{ t: 0, kind: "attr" }, { t: 40, kind: "attr" }, { t: 120, kind: "attr" }]).map((w) => w.length)).toEqual([2, 1]);
  });
});

describe("feel verdict", () => {
  const dead = judgeAction(measure({}));
  const run = (state: string, actions = [dead]): StateReport => ({ state, id: state, actions });

  test("a finding counts only when every run shows it", () => {
    const stable = stableFindings([[run("a#1"), run("b#1")], [run("a#1"), run("b#1", [])]]);
    expect([...stable.keys()]).toEqual(["a#1"]);
  });

  test("baseline splits new from known and names mended rows", () => {
    const findings = new Map([["a#1", dead.findings]]);
    const verdict = judgeFeel(["a#1", "b#1"], findings, { states: { "b#1": { 'dead-click button "X"': "fixture has no handler yet" } } });
    expect(verdict.fresh.length).toBe(1);
    expect(verdict.mended).toEqual([{ state: "b#1", key: 'dead-click button "X"' }]);
    const known = judgeFeel(["a#1"], findings, { states: { "a#1": { [dead.findings[0]!.key]: "fixture has no handler yet" } } });
    expect(known.fresh).toEqual([]);
    expect(known.known.length).toBe(1);
  });

  test("one case per state", () => {
    const cases = [
      { id: "x1", path_or_url: "frame.html", params: { entry: "e", variant: "v", theme: "A" } },
      { id: "x2", path_or_url: "frame.html", params: { entry: "e", variant: "v", theme: "B" } },
      { id: "x3", path_or_url: "frame.html", params: { entry: "e", variant: "w" } },
    ];
    expect(onePerState(cases).map((c) => c.id)).toEqual(["x1", "x3"]);
  });
});
