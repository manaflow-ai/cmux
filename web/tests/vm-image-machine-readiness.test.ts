import { describe, expect, test } from "bun:test";
import { isVmImageMachineConnectable, listVmImageManifestEntries, resolveVmImage } from "../services/vms/images/resolver";
import { parseMachineRuntime, parseVmImageManifest } from "../services/vms/images/schema";
import manifest from "../services/vms/images/manifest.json";

function firstManifestEntry() {
  const entry = listVmImageManifestEntries()[0];
  if (!entry) throw new Error("expected the checked-in image manifest to contain an entry");
  return entry;
}

describe("VM image resolver", () => {
  test("keeps every existing image legacy and out of the machine column", () => {
    for (const entry of listVmImageManifestEntries()) {
      expect(entry.machineRuntime).toEqual({ readiness: "legacy" });
      expect(isVmImageMachineConnectable(entry)).toBe(false);
    }

    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      machineConnectable: false,
    });
  });

  test("exposes machine connectability only for a complete approved protocol-v12 runtime", () => {
    const legacy = firstManifestEntry();
    const approved = {
      ...legacy,
      validationStatus: "passed",
      machineRuntime: {
        readiness: "approved",
        cmuxCommit: "a".repeat(40),
        cmuxVersion: "0.1.0",
        binarySha256: "b".repeat(64),
        protocolVersion: 12,
        bootstrapGeneration: 1,
        architecture: "x86_64",
        supervisorVersion: "cmux-cloud-supervisor-v1",
        transport: "websocket-provider-stream",
        authentication: "server-side-websocket-ticket",
        verifiedAt: "2026-08-14T12:00:00.000Z",
      },
    } as const;

    expect(isVmImageMachineConnectable(approved)).toBe(true);

    for (const validationStatus of ["unknown", "failed"] as const) {
      expect(isVmImageMachineConnectable({ ...approved, validationStatus })).toBe(false);
    }

    for (const readiness of [
      "legacy",
      "built",
      "boot_checked",
      "attach_checked",
      "resume_checked",
      "unknown",
      "failed",
    ]) {
      expect(isVmImageMachineConnectable({
        ...approved,
        machineRuntime: { ...approved.machineRuntime, readiness },
      } as never)).toBe(false);
    }

    expect(isVmImageMachineConnectable({
      ...approved,
      machineRuntime: { ...approved.machineRuntime, protocolVersion: 11 },
    })).toBe(false);

    const incompleteRuntime: Record<string, unknown> = { ...approved.machineRuntime };
    delete incompleteRuntime.binarySha256;
    expect(isVmImageMachineConnectable({
      ...approved,
      machineRuntime: incompleteRuntime,
    } as never)).toBe(false);
  });

  test("rejects approved runtimes outside the current provider launch contract", () => {
    const approved = {
      ...firstManifestEntry(),
      validationStatus: "passed",
      machineRuntime: {
        readiness: "approved",
        cmuxCommit: "a".repeat(40),
        cmuxVersion: "0.1.0",
        binarySha256: "b".repeat(64),
        protocolVersion: 12,
        bootstrapGeneration: 1,
        architecture: "x86_64",
        supervisorVersion: "cmux-cloud-supervisor-v1",
        transport: "websocket-provider-stream",
        authentication: "server-side-websocket-ticket",
        verifiedAt: "2026-08-14T12:00:00.000Z",
      },
    } as const;

    for (const machineRuntime of [
      { ...approved.machineRuntime, bootstrapGeneration: 2 },
      { ...approved.machineRuntime, architecture: "aarch64" },
      { ...approved.machineRuntime, supervisorVersion: "cmux-cloud-supervisor-v2" },
      {
        ...approved.machineRuntime,
        transport: "ssh-provider-stream",
        authentication: "ssh-edge-ticket",
      },
    ]) {
      expect(isVmImageMachineConnectable({ ...approved, machineRuntime } as never)).toBe(false);
    }

    expect(isVmImageMachineConnectable({ ...approved, provider: "future-provider" } as never)).toBe(
      false,
    );
  });

  test("requires a verification time for checked and approved machine stages", () => {
    const entry = { ...firstManifestEntry(), validationStatus: "passed" } as const;
    const runtime = {
      readiness: "approved",
      cmuxCommit: "a".repeat(40),
      cmuxVersion: "0.1.0",
      binarySha256: "b".repeat(64),
      protocolVersion: 12,
      bootstrapGeneration: 1,
      architecture: "x86_64",
      supervisorVersion: "cmux-cloud-supervisor-v1",
      transport: "websocket-provider-stream",
      authentication: "server-side-websocket-ticket",
    } as const;

    expect(isVmImageMachineConnectable({
      ...entry,
      machineRuntime: { ...runtime, verifiedAt: "2026-08-14T12:00:00.000Z" },
    })).toBe(true);
    expect(isVmImageMachineConnectable({ ...entry, machineRuntime: runtime } as never)).toBe(
      false,
    );
    expect(isVmImageMachineConnectable({
      ...entry,
      machineRuntime: { ...runtime, verifiedAt: "not-a-timestamp" },
    } as never)).toBe(false);
    expect(isVmImageMachineConnectable({
      ...entry,
      machineRuntime: { ...runtime, verifiedAt: "2026-08-14T12:00:00" },
    } as never)).toBe(false);
    expect(isVmImageMachineConnectable({
      ...entry,
      machineRuntime: { ...runtime, verifiedAt: "2026-02-30T12:00:00.000Z" },
    } as never)).toBe(false);
  });

  test("rejects unrecognized staged machine runtime fields", () => {
    const identity = {
      cmuxCommit: "a".repeat(40),
      cmuxVersion: "0.1.0",
      binarySha256: "b".repeat(64),
      protocolVersion: 12,
      bootstrapGeneration: 1,
      architecture: "x86_64",
      supervisorVersion: "cmux-cloud-supervisor-v1",
      transport: "websocket-provider-stream",
      authentication: "server-side-websocket-ticket",
    } as const;

    for (const machineRuntime of [
      { readiness: "built", ...identity, futureRequirement: true },
      {
        readiness: "boot_checked",
        ...identity,
        verifiedAt: "2026-08-14T12:00:00.000Z",
        futureRequirement: true,
      },
      {
        readiness: "approved",
        ...identity,
        verifiedAt: "2026-08-14T12:00:00.000Z",
        futureRequirement: true,
      },
    ]) {
      expect(() => parseMachineRuntime(machineRuntime)).toThrow("futureRequirement");
    }
  });

  test("rejects malformed machine identity and launch fields", () => {
    const legacy = firstManifestEntry();
    const runtime = {
      readiness: "approved",
      cmuxCommit: "a".repeat(40),
      cmuxVersion: "0.1.0",
      binarySha256: "b".repeat(64),
      protocolVersion: 12,
      bootstrapGeneration: 1,
      architecture: "x86_64",
      supervisorVersion: "cmux-cloud-supervisor-v1",
      transport: "websocket-provider-stream",
      authentication: "server-side-websocket-ticket",
      verifiedAt: "2026-08-14T12:00:00.000Z",
    } as const;

    for (const machineRuntime of [
      { ...runtime, cmuxCommit: "A".repeat(40) },
      { ...runtime, cmuxVersion: "latest" },
      { ...runtime, binarySha256: "B".repeat(64) },
      { ...runtime, protocolVersion: 12.5 },
      { ...runtime, bootstrapGeneration: 0 },
      { ...runtime, architecture: "amd64" },
      { ...runtime, supervisorVersion: "" },
      { ...runtime, authentication: "ssh-edge-ticket" },
    ]) {
      expect(isVmImageMachineConnectable({ ...legacy, machineRuntime } as never)).toBe(false);
    }
  });

});

test("legacy parsing preserves current Freestyle image metadata and pins", () => {
  const parsed = parseVmImageManifest(manifest);
  expect(parsed.images).toEqual(manifest.images.map((entry) => ({ ...entry, machineRuntime: { readiness: "legacy" } })));
});

test("schema v2 requires explicit readiness and rejects malformed runtime records", () => {
  expect(() => parseVmImageManifest({ ...manifest, schemaVersion: 2 })).toThrow("machineRuntime");
  expect(() => parseVmImageManifest({ ...manifest, images: [{ ...manifest.images[0], machineRuntime: null }] })).toThrow("machineRuntime");
});
