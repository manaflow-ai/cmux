import { expect, test } from "bun:test";
import { canApplyDeferredHydration } from "../src/diff-viewer/deferredHydration";

test("stale deferred hydration is rejected when the item identity changed", () => {
  const oldPlaceholder = { name: "a.txt", cmuxDeferredPatchText: "old patch" };
  const replacement = { name: "a.txt", cmuxDeferredPatchText: "new patch" };

  expect(canApplyDeferredHydration({ fileDiff: oldPlaceholder }, oldPlaceholder)).toBe(true);
  expect(canApplyDeferredHydration({ fileDiff: replacement }, oldPlaceholder)).toBe(false);
});
