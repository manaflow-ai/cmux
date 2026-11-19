import { expect, test } from "bun:test";
import { caseVerdict, stateVerdicts, type VerdictResult } from "./follow-verdict";

const follow = (stray: { label: string; frame: number; dy: number; follow: number }[], moving = 10) => ({
  movingFrames: moving,
  followFrames: moving - stray.length,
  strayFrames: stray.length,
  stray: stray.map((move) => ({ ...move, dx: 0 })),
  worst: Math.max(0, ...stray.map((move) => Math.abs(move.dy - move.follow))),
});
const result = (variant: string, steps: VerdictResult["play"], extra: Record<string, unknown> = {}): VerdictResult => ({
  params: { entry: "agent-pane.demo", variant, ...extra },
  ready: "1",
  load: { boxFollow: follow([]) },
  play: steps,
});

test("a state whose frames move only by the shared follow is follow only", () => {
  const verdict = caseVerdict(result("stream", { steps: [{ step: "click play", boxFollow: follow([]) }] }));
  expect(verdict).toMatchObject({ key: "default\tagent-pane.demo#stream", verdict: "follow only", strayFrames: 0 });
});

test("a stray move names the step, the frame, the box and the px", () => {
  const verdict = caseVerdict(
    result("jump", { steps: [{ step: "click .up", boxFollow: follow([{ label: "row a", frame: 31, dy: 8, follow: 0 }]) }] }),
  );
  expect(verdict.verdict).toBe("real shift");
  expect(verdict.worst).toBe(8);
  expect(verdict.where).toEqual(["click .up, frame 31: row a [0 8] (follow 0)"]);
});

test("a run with no follow judgement says so, and a state keeps its worst case under its arm", () => {
  expect(caseVerdict({ params: { entry: "x", variant: "y" }, ready: "1", load: {} }).verdict).toBe("not judged");
  const verdicts = stateVerdicts([
    result("jump", { steps: [{ step: "a", boxFollow: follow([{ label: "r", frame: 2, dy: 3, follow: 0 }]) }] }),
    result("jump", { steps: [{ step: "a", boxFollow: follow([{ label: "r", frame: 2, dy: 9, follow: 0 }]) }] }),
    result("jump", { steps: [] }, { exp: "jump-up", arm: "on" }),
    { ...result("jump", { steps: [] }), ready: "timeout" },
  ]);
  expect(verdicts.get("default\tagent-pane.demo#jump")?.worst).toBe(9);
  expect(verdicts.get("jump-up=on\tagent-pane.demo#jump")?.verdict).toBe("follow only");
});
