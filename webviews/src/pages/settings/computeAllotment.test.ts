// Settings > Team > Compute's view-model: the proposal sentence, each dial position's figure, the
// member rows (order, detail, notes), the meter and the inbox's reason cards, from the backend's view.
import { expect, test } from "bun:test";
import { commitFor, computeModel, money, proposalSentence } from "./computeAllotment";
import { MOCK_AS_OF, mockAllotments, runMockAllotment } from "./mockAllotments";

const en = "en";

test("money drops whole cents and keeps the rest", () => {
  expect(money(40_000_000, en)).toBe("$40");
  expect(money(12_500_000, en)).toBe("$12.50");
  expect(money(0, en)).toBe("$0");
});

test("each state's proposal is one plain sentence", () => {
  expect(proposalSentence(mockAllotments.proposalUp, en)).toBe(
    "Austin passed the allotment 4 times: scaling up costs $40 a month.",
  );
  expect(proposalSentence(mockAllotments.proposalDown, en)).toBe(
    "3 of 7 members used nothing in 14 days: scaling down saves $40 a month.",
  );
  expect(proposalSentence(mockAllotments.hold, en)).toBe("Usage fits the allotment. Nothing to decide.");
  expect(proposalSentence(mockAllotments.empty, en)).toBe(
    "No one has used Cloud yet. 7 seats include $175 a month. Nothing to decide.",
  );
  expect(proposalSentence(mockAllotments.autoOn, en)).toBe(
    "Agents: CI is using $9 an hour: Auto scales up, adding $40 a month.",
  );
});

test("no copy carries an em dash or an internal vendor name", () => {
  for (const view of Object.values(mockAllotments)) {
    const model = computeModel(view, en);
    const copy = JSON.stringify(model);
    expect(copy).not.toContain("—");
    expect(copy.toLowerCase()).not.toMatch(/freestyle|gcp|blacksmith|e2b|daytona|morph/);
  }
});

test("the dial preselects the proposal and shows the monthly allotment under each position", () => {
  const model = computeModel(mockAllotments.proposalUp, en);
  expect(model.proposed).toBe("up");
  expect(model.options.map((option) => [option.position, option.figure, option.change, option.proposed])).toEqual([
    ["down", "$275 a month", "saves $20 a month", false],
    ["hold", "$300 a month", "no change", false],
    ["up", "$350 a month", "costs $40 a month", true],
  ]);
  const down = computeModel(mockAllotments.proposalDown, en);
  expect(down.options.find((option) => option.proposed)?.figure).toBe("$250 a month");
});

test("the empty team holds, with the dial and Auto locked and no table", () => {
  const model = computeModel(mockAllotments.empty, en);
  expect(model.empty).toBe(true);
  expect(model.proposed).toBe("hold");
  expect(model.locked).toBe(true);
  expect(model.options.every((option) => option.disabled)).toBe(true);
  expect(model.hardCap).toContain("No hard cap");
});

test("down is unavailable at no commit unless it is the proposal", () => {
  const atZero = runMockAllotment(mockAllotments.proposalDown, { action: "down" });
  expect(atZero.allotment?.commit_micros).toBe(25_000_000);
  const again = runMockAllotment(atZero, { action: "down" });
  expect(again.allotment?.commit_micros).toBe(0);
  expect(computeModel(again, en).options[0]!.disabled).toBe(true);
});

test("rows sort by the last 14 days' use and carry their detail and notes", () => {
  const model = computeModel(mockAllotments.proposalUp, en);
  expect(model.rows.map((row) => row.member)).toEqual([
    "Leo",
    "Lawrence",
    "Austin",
    "Agents: CI",
    "Agents: lanes",
    "Aziz",
    "Sam",
  ]);
  const [leo, , austin] = model.rows;
  expect(leo).toEqual({
    member: "Leo",
    name: "Leo",
    detail: "13 of 14 days, Chief Max",
    month: "$96",
    share: "32%",
    note: "",
  });
  expect(austin!.detail).toBe("11 of 14 days");
  expect(austin!.note).toBe("passed allotment 4x, could use Chief Plus: +$40");
  expect(model.rows.at(-1)!.note).toBe("unused");
  expect(model.spares).toMatchObject({ member: "Warm spares", detail: "ours", month: "$0" });
});

test("members print with the view's display names, by id where it has none", () => {
  const view = { ...mockAllotments.proposalUp, names: { Austin: "Austin Example", Leo: "" } };
  const model = computeModel(view, en);
  const austin = model.rows.find((row) => row.member === "Austin")!;
  expect(austin.name).toBe("Austin Example");
  expect(model.rows.find((row) => row.member === "Leo")!.name).toBe("Leo");
  expect(model.sentence).toBe("Austin Example passed the allotment 4 times: scaling up costs $40 a month.");
  expect(model.meter.segments.find((segment) => segment.member === "Austin")!.name).toBe("Austin Example");
});

test("the meter cuts the month into member segments with ticks at the allotment and the cap", () => {
  const { meter } = computeModel(mockAllotments.proposalUp, en);
  expect(meter.segments.map((segment) => segment.member)).not.toContain("Sam");
  expect(meter.allot).toBeCloseTo(300 / 500);
  expect(meter.cap).toBe(1);
  expect(meter.allotLabel).toBe("Allotment $300");
  expect(meter.capLabel).toBe("Hard cap $500");
});

test("reason cards say what Accept does; a tier change has no Accept yet", () => {
  const model = computeModel(mockAllotments.proposalUp, en);
  expect(model.reasons).toEqual([
    { key: "over-0", text: "Austin passed the allotment 4 times. Scaling up costs $40 a month.", accept: "up" },
    { key: "tier-1", text: "Austin could use Chief Plus: +$40 a month.", accept: null },
  ]);
  expect(computeModel(mockAllotments.proposalDown, en).reasons[0]!.accept).toBe("down");
  expect(model.holdLine).toBe("Holding at $300, Auto off");
  expect(computeModel(mockAllotments.autoOn, en).holdLine).toBe("Holding at $300, Auto on");
});

test("the mock backend applies the proposal, snoozes on hold and flips Auto alone", () => {
  const up = runMockAllotment(mockAllotments.proposalUp, { action: "up" });
  expect(commitFor(mockAllotments.proposalUp, "up")).toBe(125_000_000);
  expect(up.allotment?.commit_micros).toBe(125_000_000);
  expect(up.decision.allot_micros).toBe(350_000_000);
  expect(up.decision.position).toBe("hold");
  const held = runMockAllotment(mockAllotments.proposalUp, { action: "hold" });
  expect(held.allotment?.snoozed_until).toBe(MOCK_AS_OF + 14 * 86_400_000);
  expect(proposalSentence(held, en)).toBe("Holding at $300 until Dec 6, 2026. Nothing to decide.");
  const auto = runMockAllotment(mockAllotments.proposalUp, { auto: true });
  expect(auto.allotment?.mode).toBe("auto");
  expect(auto.allotment?.snoozed_until).toBeNull();
  expect(auto.decision).toEqual(mockAllotments.proposalUp.decision);
});
