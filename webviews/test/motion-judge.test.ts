import { describe, expect, test } from "bun:test";
import { Window } from "happy-dom";
import contract from "../../schemas/layout-motion/contract.json";
import vectors from "../../schemas/layout-motion/vectors.json";
import { MEDIA_SELECTOR, TRACK_SELECTOR } from "../src/layout/boxSample";
import { MOTION_EVENTS, SURFACES, declareMove, openDeclarations, surfaceOf } from "../src/layout/motionContract";
import { judgeMotion, type JudgeDeclaration, type JudgeFrame, type JudgeSample } from "../src/layout/motionJudge";

type VectorSample = { surface: string; box: number[] } & Omit<JudgeSample, "surface" | "box" | "label">;
type VectorFrame = { samples: Record<string, VectorSample>; declared?: JudgeDeclaration[] };

const frameOf = ({ samples, declared }: VectorFrame): JudgeFrame => ({
  samples: new Map(
    Object.entries(samples).map(([id, { box, ...rest }]) => [
      id,
      { ...rest, label: id, box: { x: box[0]!, y: box[1]!, width: box[2]!, height: box[3]! } },
    ]),
  ),
  declared: declared ?? [],
});

describe("the judge agrees with schemas/layout-motion/vectors.json", () => {
  for (const vector of vectors.cases as { name: string; frames: VectorFrame[]; undeclared: number }[])
    test(vector.name, () => {
      const verdict = judgeMotion(vector.frames.map(frameOf));
      expect(verdict.undeclared).toBe(vector.undeclared);
    });
});

test("every surface declares only events the contract names, and every web surface the gallery samples", () => {
  for (const surface of SURFACES) for (const event of surface.moves) expect(MOTION_EVENTS).toContain(event);
  for (const surface of SURFACES) expect(Object.keys(contract.sizes)).toContain(surface.size);
  // Every box the sampler reads has a surface of its own (else it would be judged as `tracked`).
  const window = new Window();
  const doc = window.document as unknown as Document;
  doc.body.innerHTML = `
    <div data-row-id="r1"></div><div class="acpmux-composer-box"></div><div role="menu"></div>
    <div role="option"></div><div role="row"></div><div role="tab"></div><img class="cv-img">`;
  const ids = [...doc.querySelectorAll(`${TRACK_SELECTOR},${MEDIA_SELECTOR}`)].map((element) => surfaceOf(element).id);
  expect(ids).toEqual(["transcript-row", "composer", "popup", "popup", "list-row", "tab", "chat-media"]);
});

test("a declared move holds until it ends or its time runs out", () => {
  const end = declareMove({ event: "stream-append", scope: "all", by: "test" });
  declareMove({ event: "older-history", scope: "all" }, { ms: 50 });
  const now = performance.now();
  expect(openDeclarations(now).map((declaration) => declaration.event)).toEqual(["stream-append", "older-history"]);
  expect(openDeclarations(now + 100).map((declaration) => declaration.event)).toEqual(["stream-append"]);
  end();
  expect(openDeclarations(now + 100)).toEqual([]);
});

test("the judge names the first move of each box, and counts each box once", () => {
  const still = (y: number): JudgeFrame => ({
    samples: new Map([["a", { label: "a", surface: "transcript-row", box: { x: 0, y, width: 10, height: 10 } }]]),
    declared: [],
  });
  const verdict = judgeMotion([still(0), still(0), still(0), still(5), still(5), still(5), still(9)]);
  expect(verdict.undeclared).toBe(1);
  expect(verdict.moves).toEqual([
    { label: "a", surface: "transcript-row", frame: 3, dx: 0, dy: 5, dw: 0, dh: 0, during: [] },
  ]);
});
