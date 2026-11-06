import { expect, test } from "bun:test";
import { checkRunningLineLoops, hasCompleteRunningLineShimmer, type RunningLineLoop } from "./runningLineMotion";

const element = (className: string, parent?: Element): Element => {
  const classes = new Set(className.split(/\s+/).filter(Boolean));
  return {
    classList: { contains: (name: string) => classes.has(name) },
    parentElement: parent ?? null,
  } as unknown as Element;
};

const pair = () => {
  const band = element("cv-shimmer__band");
  const lit = element("cv-shimmer__lit", band);
  return { band, lit };
};

const loop = (
  name: string,
  target: Element | null,
  overrides: Partial<
    Pick<RunningLineLoop, "playState" | "playbackRate" | "currentTime" | "duration" | "progress">
  > = {},
): RunningLineLoop => ({
  name,
  target,
  playState: "running",
  playbackRate: 1,
  currentTime: 1,
  duration: 2_400,
  progress: 0.5,
  ...overrides,
});

test("the approved shimmer has one active loop on each text layer", () => {
  const { band, lit } = pair();
  const check = checkRunningLineLoops([loop("cmux-shimmer-band", band), loop("cmux-shimmer-lit", lit)]);
  expect(check.unapproved).toHaveLength(0);
  expect(check.duplicateTargets).toHaveLength(0);
  expect(hasCompleteRunningLineShimmer(check)).toBe(true);
});

test("a duplicate loop on one layer is still a running-line failure", () => {
  const { band, lit } = pair();
  const check = checkRunningLineLoops([
    loop("cmux-shimmer-band", band),
    loop("cmux-shimmer-band", band),
    loop("cmux-shimmer-lit", lit),
  ]);
  expect(check.duplicateTargets).toEqual([band]);
  expect(hasCompleteRunningLineShimmer(check)).toBe(false);
});

test("paused, zero-rate, stalled, and out-of-range layers are not treated as shimmer", () => {
  const { band, lit } = pair();
  for (const overrides of [
    { playState: "paused" as const },
    { playbackRate: 0 },
    { currentTime: null },
    { progress: -0.1 },
    { progress: 1.1 },
  ]) {
    const check = checkRunningLineLoops([loop("cmux-shimmer-band", band, overrides), loop("cmux-shimmer-lit", lit)]);
    expect(hasCompleteRunningLineShimmer(check)).toBe(false);
  }
});

test("names cannot approve null, arbitrary, or swapped shimmer targets", () => {
  const { band, lit } = pair();
  const arbitrary = element("other");
  const cases = [
    [loop("cmux-shimmer-band", null), loop("cmux-shimmer-lit", lit)],
    [loop("cmux-shimmer-band", arbitrary), loop("cmux-shimmer-lit", lit)],
    [loop("cmux-shimmer-band", lit), loop("cmux-shimmer-lit", band)],
  ];
  for (const check of cases.map(checkRunningLineLoops)) {
    expect(hasCompleteRunningLineShimmer(check)).toBe(false);
  }
});

test("an active spinner or an idle/reduced-motion line is not approved", () => {
  const { band, lit } = pair();
  const spinner = checkRunningLineLoops([
    loop("cmux-shimmer-band", band),
    loop("cmux-shimmer-lit", lit),
    loop("cmux-spin", element("cv-spinner")),
  ]);
  expect(spinner.unapproved.map((entry) => entry.name)).toEqual(["cmux-spin"]);
  expect(hasCompleteRunningLineShimmer(spinner)).toBe(false);
  const idle = checkRunningLineLoops([]);
  expect(idle).toEqual({ shimmer: [], unapproved: [], duplicateTargets: [] });
  expect(hasCompleteRunningLineShimmer(idle)).toBe(false);
});
