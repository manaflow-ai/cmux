// The team's hold for its people's machines on the Compute card: the view-model's options and line,
// the mock backend's set and clear, and that the card draws the control only where a layout asks.
import { afterAll, expect, test } from "bun:test";
import { computeModel, holdModel } from "./computeAllotment";
import { mockAllotments, runMockAllotment } from "./mockAllotments";
import { installDom } from "./testDom";

const restore = installDom();
afterAll(() => restore());
const { renderCard, click } = await import("./testing");
const { ComputeCard, ComputeCardDemo } = await import("./components/ComputeCard");

test("no hold set: Off is chosen and the line says machines pause when idle", () => {
  const hold = holdModel(mockAllotments.hold);
  expect(hold.seconds).toBeNull();
  expect(hold.options.map((option) => [option.label, option.selected])).toEqual([
    ["Off", true],
    ["5 min", false],
    ["15 min", false],
    ["30 min", false],
  ]);
  expect(hold.line).toBe("Machines pause when idle and wake on the next message.");
});

test("the mock backend sets and clears the hold and leaves the commit and the proposal alone", () => {
  const before = mockAllotments.proposalUp;
  const set = runMockAllotment(before, { person_hold_seconds: 900 });
  expect(set.allotment?.person_hold_seconds).toBe(900);
  expect(set.allotment?.commit_micros).toBe(before.allotment?.commit_micros ?? 0);
  expect(set.decision).toEqual(before.decision);
  expect(computeModel(set, "en").hold.line).toBe(
    "A machine someone is chatting on stays ready for 15 minutes after each reply. Agents' machines still pause when idle.",
  );
  const cleared = runMockAllotment(set, { person_hold_seconds: null });
  expect(cleared.allotment && "person_hold_seconds" in cleared.allotment).toBe(false);
});

test("a number that is not one of the choices reads as no hold", () => {
  const view = structuredClone(runMockAllotment(mockAllotments.hold, { person_hold_seconds: 300 }));
  view.allotment!.person_hold_seconds = 42;
  expect(holdModel(view).seconds).toBeNull();
});

test("the app's card draws no hold control; the gallery's draws it and one click sets it", async () => {
  const app = await renderCard(<ComputeCard layout="ledger" />, {
    setup: (provider) => {
      provider.allotment = structuredClone(mockAllotments.hold);
    },
  });
  expect(app.container.querySelector("[data-compute-hold]")).toBeNull();
  app.unmount();

  const demo = await renderCard(
    <ComputeCardDemo view={mockAllotments.hold} layout="ledger" holdControl="choices" answer={runMockAllotment} />,
  );
  const pressed = () => demo.container.querySelector('[data-compute-hold-option][aria-pressed="true"]');
  expect(pressed()?.getAttribute("data-compute-hold-option")).toBe("off");
  await click(demo.container.querySelector<HTMLButtonElement>('[data-compute-hold-option="1800"]')!);
  expect(pressed()?.getAttribute("data-compute-hold-option")).toBe("1800");
  expect(demo.container.querySelector("[data-compute-ready-line]")?.textContent).toContain("30 minutes");
  demo.unmount();
});
