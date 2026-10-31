// A message's pull request chips (summary/pullRequestChipPlan.ts): a chip is its number, or its
// number and a title long enough to read, never a two-letter stub ("#29007 cm…"); what does not fit
// goes behind +N, which lists it.
import { expect, test } from "bun:test";
import {
  planPullRequestChips,
  pullRequestChipsWidth,
  type PullRequestChipSizes,
} from "../src/agent-session/acpmux/summary/pullRequestChipPlan";

const sizes = (overrides: Partial<PullRequestChipSizes>): PullRequestChipSizes => ({
  room: 360,
  gap: 8,
  numbers: [56, 56],
  titles: [220, 180],
  more: [30, 30],
  minTitle: 88,
  limit: 2,
  total: 55,
  ...overrides,
});

test("two titled chips when both readable titles fit beside the overflow", () => {
  // 56 + 88 + 8 + 56 + 88 + 8 + 30 = 334 <= 360
  expect(planPullRequestChips(sizes({}))).toMatchObject({ count: 2, titled: true });
});

test("one titled chip before two chips with stub titles", () => {
  // Two titled chips need 334; one titled chip needs 56 + 88 + 8 + 30 = 182.
  expect(planPullRequestChips(sizes({ room: 300 }))).toMatchObject({ count: 1, titled: true });
});

test("numbers alone when not even one readable title fits", () => {
  // One titled chip needs 182; two numbers need 56 + 8 + 56 + 8 + 30 = 158.
  expect(planPullRequestChips(sizes({ room: 170 }))).toMatchObject({ count: 2, titled: false });
  expect(planPullRequestChips(sizes({ room: 120 }))).toMatchObject({ count: 1, titled: false });
});

test("a title is never cut below its readable minimum", () => {
  for (let room = 40; room <= 600; room += 7) {
    const plan = planPullRequestChips(sizes({ room }));
    if (!plan.titled) continue;
    // Whatever the plan draws fits with every title at its readable minimum (or whole, if shorter).
    expect(pullRequestChipsWidth(sizes({ room }), plan.count, true)).toBeLessThanOrEqual(room);
  }
});

test("a short title counts at its own width", () => {
  // A 40px title needs only 40, so two titled chips fit in 56 + 40 + 8 + 56 + 40 + 8 + 30 = 238.
  expect(planPullRequestChips(sizes({ room: 240, titles: [40, 40] }))).toMatchObject({ count: 2, titled: true });
});

test("chips with no titles draw numbers", () => {
  expect(planPullRequestChips(sizes({ titles: [0, 0] }))).toMatchObject({ count: 2, titled: false });
});

test("the overflow is counted only while something is left out", () => {
  const one = sizes({ total: 1, numbers: [56], titles: [220] });
  expect(pullRequestChipsWidth(one, 1, true)).toBe(56 + 88);
  expect(pullRequestChipsWidth(sizes({}), 2, false)).toBe(56 + 8 + 56 + 8 + 30);
  expect(pullRequestChipsWidth(sizes({ total: 2 }), 2, false)).toBe(56 + 8 + 56);
});

test("numbers-only and one-chip treatments", () => {
  expect(planPullRequestChips(sizes({ withTitles: false }))).toMatchObject({ count: 2, titled: false });
  expect(planPullRequestChips(sizes({ limit: 1 }))).toMatchObject({ count: 1, titled: true });
});

test("+N is measured for the count it would follow", () => {
  // 11 PRs: one chip leaves +10 (wider), two leave +9. Two titled chips fit only with the narrower +9.
  const eleven = sizes({ total: 11, more: [40, 30], room: 56 + 88 + 8 + 56 + 88 + 8 + 30 });
  expect(planPullRequestChips(eleven)).toMatchObject({ count: 2, titled: true });
  expect(pullRequestChipsWidth(eleven, 1, true)).toBe(56 + 88 + 8 + 40);
});

test("a title is short by its measured width, the rule the width counts with", () => {
  expect(planPullRequestChips(sizes({ titles: [60, 200] })).short).toEqual([true, false]);
  expect(planPullRequestChips(sizes({ titles: [88, 89] })).short).toEqual([true, false]);
});

test("at least one chip always shows", () => {
  expect(planPullRequestChips(sizes({ room: 0 }))).toMatchObject({ count: 1, titled: false });
});
