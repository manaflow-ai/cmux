import { describe, expect, test } from "bun:test";
import {
  hiveRuntimePlacementState,
  isCurrentHiveRuntimePlacement,
  type CloudRuntimeRow,
} from "../services/vms/runtimeRegistry";

const runtime: CloudRuntimeRow = {
  id: "00000000-0000-4000-8000-000000000001",
  ownerTeamId: "team-runtime",
  journalSessionId: "session_00000000000000000000000000000001",
  machineId: "00000000-0000-4000-8000-000000000002",
  placementGeneration: 7,
  createdAt: new Date("2026-09-21T00:00:00Z"),
};
const placement = { runtimeId: runtime.id, machineId: runtime.machineId!, generation: 7 };
const machine = (status: "running" | "paused" | "provisioning" | "failed" | "destroyed") =>
  ({ status } as NonNullable<Parameters<typeof hiveRuntimePlacementState>[0]>);

describe("Hive runtime placement fence", () => {
  test.each([
    ["running", "running"],
    ["paused", "paused"],
    ["provisioning", "provisioning"],
    ["failed", "unplaced"],
    ["destroyed", "unplaced"],
  ] as const)("derives %s placement state", (status, expected) => {
    expect(hiveRuntimePlacementState(machine(status))).toBe(expected);
  });

  test("derives an unplaced state when the machine row is gone", () => {
    expect(hiveRuntimePlacementState(null)).toBe("unplaced");
  });

  test("accepts the complete current incarnation", () => {
    expect(isCurrentHiveRuntimePlacement(runtime, placement)).toBe(true);
  });
  test.each([6, 8, 0, -1, 7.1, Number.NaN, Number.POSITIVE_INFINITY])("rejects generation %s", (generation) => {
    expect(isCurrentHiveRuntimePlacement(runtime, { ...placement, generation })).toBe(false);
  });
  test("rejects another runtime or machine even at the same generation", () => {
    expect(isCurrentHiveRuntimePlacement(runtime, { ...placement, runtimeId: "another" })).toBe(false);
    expect(isCurrentHiveRuntimePlacement(runtime, { ...placement, machineId: "another" })).toBe(false);
    expect(isCurrentHiveRuntimePlacement(runtime, { ...placement, runtimeId: "" })).toBe(false);
    expect(isCurrentHiveRuntimePlacement({ ...runtime, machineId: null }, placement)).toBe(false);
  });
});
