import { expect, test } from "bun:test";
import { projectLiveProgress } from "./liveProgress";

const plan = [{ content: "Check", status: "in_progress" as const }];

test("reuses the projection while tokens stream", () => {
  const first = projectLiveProgress(undefined, plan, true);
  expect(projectLiveProgress(first, plan, true)).toBe(first);
  expect(projectLiveProgress(first, plan, false)).not.toBe(first);
});

test("holds one projection across a streamed token burst", () => {
  let current = projectLiveProgress(undefined, plan, true);
  const identities = new Set<object>();
  for (let token = 0; token < 200; token++) {
    current = projectLiveProgress(current, plan, true);
    if (current) identities.add(current);
  }
  expect(identities.size).toBe(1);
});

test("clearing a plan removes Progress", () => {
  const first = projectLiveProgress(undefined, plan, true);
  expect(projectLiveProgress(first, [], true)).toBeUndefined();
});

test("derives the completed count only when the checklist changes", () => {
  const first = projectLiveProgress(undefined, plan, true);
  expect(first?.completed).toBe(0);
  expect(first?.total).toBe(1);
  const changed = projectLiveProgress(first, [{ content: "Check", status: "completed" }], true);
  expect(changed).not.toBe(first);
  expect(changed?.completed).toBe(1);
  expect(changed?.total).toBe(1);
  expect(projectLiveProgress(changed, changed?.plan, false)).not.toBe(changed);
  expect(projectLiveProgress(changed, changed?.plan, false)?.completed).toBe(1);
});
