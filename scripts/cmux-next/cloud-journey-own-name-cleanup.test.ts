import { describe, expect, test } from "bun:test";
import { autoMachineName, ownNamedMachines } from "./cloud-journey";
import { FIXTURE_MACHINE, FIXTURE_TWIN_MACHINE, runJourney } from "./cloud-journey-fake";

// Run 46059808882 (jr-mwzf7mv7): create answered one id, the run deleted it, and a second machine under the run's own
// name stayed paused on the production probe account, holding a plan slot until the next run's 3 h sweep.
describe("the journey's cleanup deletes every machine under its own names", () => {
  test("ownNamedMachines: own names only, live only, minus the excluded ids", () => {
    const tag = "jr-mwzf7mv7";
    const rows = [
      { id: "vm_a", name: autoMachineName(tag, false), status: "paused" },
      { id: "vm_b", name: `${autoMachineName(tag, true)} gateway`, status: "running" },
      { id: "vm_c", name: `${autoMachineName(tag, false)} cold`, status: "running" },
      { id: "vm_d", name: autoMachineName(tag, false), status: "deleting" },
      { id: "vm_e", name: autoMachineName(tag, false), status: "deleted" },
      { id: "vm_f", name: autoMachineName("jr-other", false), status: "paused" },
      { id: "vm_g", name: `cloud journey ${tag}`, status: "paused" },
      { id: "vm_h", name: "cmux-56b7c82a30ed5eb2b68d7828dd410601c7c0127a", status: "paused" },
      { id: "vm_i", name: autoMachineName(tag, false), status: "running" },
    ];
    expect(ownNamedMachines(rows, tag, { exclude: ["vm_i", null] }).map((r) => r.id)).toEqual(["vm_a", "vm_b", "vm_c"]);
    // A --keep run's machine is the operator's until --cleanup-tag --kept names it.
    expect(ownNamedMachines(rows, tag, { kept: true, exclude: ["vm_i"] }).map((r) => r.id)).toEqual(["vm_a", "vm_b", "vm_c", "vm_g"]);
  });

  test("a create that left a second machine by the run's name: the run deletes both", () => {
    const { log, steps } = runJourney({ twin: true });
    expect(log).toContain("delete");
    expect(log).toContain("delete twin");
    const own = steps.find((s) => s.step === "delete own-named machine (cleanup)");
    expect(own).toMatchObject({ status: "pass" });
    expect(own?.detail).toContain(FIXTURE_TWIN_MACHINE);
    expect(steps.some((s) => s.step.includes("cleanup") && s.detail?.includes(FIXTURE_MACHINE) && s.step === "delete own-named machine (cleanup)")).toBe(false);
  });

  test("no second machine: one delete, no own-name step", () => {
    const { log, steps } = runJourney({});
    expect(log.filter((l) => l === "delete" || l === "delete twin")).toEqual(["delete"]);
    expect(steps.some((s) => s.step === "delete own-named machine (cleanup)")).toBe(false);
  });
});
