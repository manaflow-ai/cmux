import { describe, expect, test } from "bun:test";
import { runJourney } from "./cloud-journey-fake.ts";
import { Journey, UNRECORDED_THROW_STEP } from "./cloud-journey.ts";

// Run 46134450737, kill-dst: a raw call between steps threw, the run's catch took it as "the failed step is recorded",
// and the journey read PASS with exit 0 while its later checks (the move drills) never ran.
describe("a throw outside every step fails the run", () => {
  test("the journey: the script's fs/write throws, the run is red and names it", () => {
    const { steps, stdout } = runJourney({ scriptWriteThrows: true });
    const stopped = steps.find((s) => s.step === UNRECORDED_THROW_STEP);
    expect(stopped?.status).toBe("fail");
    expect(stopped?.detail).toContain("fetch failed (fixture)");
    expect(stdout).toContain("FAIL ");
  });

  test("a step's own fail is not recorded twice", async () => {
    const J = new Journey({ name: "fixture" } as any, null, {});
    const e = await J.step("a step", async () => { throw new Error("boom"); }).catch((x) => x);
    J.unrecorded(e);
    expect(J.steps.map((s) => `${s.step} ${s.status}`)).toEqual(["a step fail"]);
    J.unrecorded(new Error("between steps"));
    expect(J.steps.at(-1)).toMatchObject({ step: UNRECORDED_THROW_STEP, status: "fail" });
  });
});
