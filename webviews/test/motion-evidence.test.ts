import { expect, test } from "bun:test";
import { judgeMotionProbe, motionMetrics, type MotionSample } from "../src/gallery/motionEvidence";

const samples = (values: number[], secondary?: number[]): MotionSample[] =>
  values.map((value, index) => ({ t: index * 16.7, value, secondary: secondary?.[index] }));

test("streaming follow treats a planted bottom as stable", () => {
  const result = motionMetrics(samples([100, 100.5, 100.25, 100.4], [0.5, 1, 0.4, 0.7]));
  expect(result.signChanges).toBe(2);
  expect(
    judgeMotionProbe(
      { kind: "streaming-follow", target: ".acpmux-scroll" },
      samples([100, 100.5, 100.25], [0.5, 1, 0.4]),
    ).status,
  ).toBe("pass");
});

test("streaming follow rejects a visible bottom gap", () => {
  const result = judgeMotionProbe(
    { kind: "streaming-follow", target: ".acpmux-scroll" },
    samples([100, 98, 100], [0.5, 5.2, 0.5]),
  );
  expect(result.status).toBe("fail");
  expect(result.problems[0]).toContain("bottom gap");
});

test("thumb and slider probes require a settled motion", () => {
  const result = judgeMotionProbe({ kind: "scroll-thumb", target: ".scroll", visual: ".thumb" }, samples([20, 30, 40]));
  expect(result.status).toBe("fail");
  expect(result.problems).toContain("motion did not settle");
});
