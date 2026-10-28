import { expect, test } from "bun:test";
import { checkRunningLineLoops, hasCompleteRunningLineShimmer } from "./runningLineMotion";

const loop = (name: string, target: object): { name: string; target: object } => ({ name, target });

test("the approved shimmer has one loop on each text layer", () => {
  const check = checkRunningLineLoops([
    loop("cmux-shimmer-band", {}),
    loop("cmux-shimmer-lit", {}),
  ]);
  expect(check.unapproved).toHaveLength(0);
  expect(check.duplicateTargets).toHaveLength(0);
  expect(hasCompleteRunningLineShimmer(check)).toBe(true);
});

test("a duplicate loop on one layer is still a running-line failure", () => {
  const layer = {};
  const check = checkRunningLineLoops([
    loop("cmux-shimmer-band", layer),
    loop("cmux-shimmer-band", layer),
    loop("cmux-shimmer-lit", {}),
  ]);
  expect(check.duplicateTargets).toEqual([layer]);
  expect(hasCompleteRunningLineShimmer(check)).toBe(false);
});

test("a missing shimmer layer or a spinner on the text line is not approved", () => {
  const missingLayer = checkRunningLineLoops([loop("cmux-shimmer-band", {})]);
  expect(hasCompleteRunningLineShimmer(missingLayer)).toBe(false);

  const spinner = checkRunningLineLoops([
    loop("cmux-shimmer-band", {}),
    loop("cmux-shimmer-lit", {}),
    loop("cmux-spin", {}),
  ]);
  expect(spinner.unapproved.map((entry) => entry.name)).toEqual(["cmux-spin"]);
  expect(hasCompleteRunningLineShimmer(spinner)).toBe(false);
});

test("an idle or reduced-motion line has no running loops", () => {
  const check = checkRunningLineLoops([]);
  expect(check).toEqual({ shimmer: [], unapproved: [], duplicateTargets: [] });
  expect(hasCompleteRunningLineShimmer(check)).toBe(false);
});
