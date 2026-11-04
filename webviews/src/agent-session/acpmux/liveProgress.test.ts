import { expect, test } from "bun:test";
import { projectLiveProgress } from "./liveProgress";

const plan = [{ content: "Check", status: "in_progress" as const }];

test("reuses the projection while tokens stream", () => {
  const first = projectLiveProgress(undefined, plan, true);
  expect(projectLiveProgress(first, plan, true)).toBe(first);
  expect(projectLiveProgress(first, plan, false)).not.toBe(first);
});

test("clearing a plan removes Progress", () => {
  const first = projectLiveProgress(undefined, plan, true);
  expect(projectLiveProgress(first, [], true)).toBeUndefined();
});
