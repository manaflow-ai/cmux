import { describe, expect, test } from "bun:test";
import {
  isVmImageMachineConnectable,
  listVmImageManifestEntries,
} from "../services/vms/images/resolver";
import {
  parseMachineRuntime,
  MACHINE_CONNECTABLE_AUTHENTICATION,
  MACHINE_CONNECTABLE_BOOTSTRAP_GENERATION,
  MACHINE_CONNECTABLE_ARCHITECTURE,
  MACHINE_CONNECTABLE_MUX_PROTOCOL_VERSION,
  MACHINE_CONNECTABLE_SUPERVISOR_VERSION,
  MACHINE_CONNECTABLE_TRANSPORT,
} from "../services/vms/images/schema";

describe("Cloud VM image machine readiness", () => {
  test("current Freestyle catalog stays legacy and non-connectable", () => {
    const entries = listVmImageManifestEntries();
    expect(entries.length).toBeGreaterThan(0);
    expect(entries.every((entry) => entry.machineRuntime.readiness === "legacy")).toBe(true);
    expect(entries.every((entry) => !isVmImageMachineConnectable(entry))).toBe(true);
  });

  test("requires the full approved runtime contract", () => {
    const runtime = {
      readiness: "approved",
      cmuxCommit: "a".repeat(40),
      cmuxVersion: "0.1.0",
      binarySha256: "b".repeat(64),
      protocolVersion: MACHINE_CONNECTABLE_MUX_PROTOCOL_VERSION,
      bootstrapGeneration: MACHINE_CONNECTABLE_BOOTSTRAP_GENERATION,
      architecture: MACHINE_CONNECTABLE_ARCHITECTURE,
      supervisorVersion: MACHINE_CONNECTABLE_SUPERVISOR_VERSION,
      transport: MACHINE_CONNECTABLE_TRANSPORT,
      authentication: MACHINE_CONNECTABLE_AUTHENTICATION,
      verifiedAt: "2026-09-17T00:00:00.000Z",
    } as const;

    expect(parseMachineRuntime(runtime)).toEqual(runtime);
    expect(isVmImageMachineConnectable({
      provider: "freestyle",
      validationStatus: "passed",
      machineRuntime: runtime,
    })).toBe(true);
    expect(isVmImageMachineConnectable({
      provider: "freestyle",
      validationStatus: "passed",
      machineRuntime: { ...runtime, protocolVersion: 11 },
    })).toBe(false);
  });
});
