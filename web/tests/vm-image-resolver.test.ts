import { describe, expect, test } from "bun:test";
import {
  isVmImageMachineConnectable,
  imageUsesBakedFreestyleSignedAdmin,
  listVmImageManifestEntries,
  resolveVmImage,
} from "../services/vms/images/resolver";
import { VmImageConfigError } from "../services/vms/errors";

function captureImageConfigError(fn: () => unknown): VmImageConfigError {
  try {
    fn();
  } catch (err) {
    if (err instanceof VmImageConfigError) return err;
    throw err;
  }
  throw new Error("expected VmImageConfigError to be thrown");
}

describe("VM image resolver", () => {
  test("keeps every existing image legacy and out of the machine column", () => {
    for (const entry of listVmImageManifestEntries()) {
      expect(entry.machineRuntime).toEqual({ readiness: "legacy" });
      expect(isVmImageMachineConnectable(entry)).toBe(false);
    }

    expect(resolveVmImage("e2b", "cmuxd-ws:tooling-20260509f", {})).toMatchObject({
      machineConnectable: false,
    });
  });

  test("exposes machine connectability only for a complete approved protocol-v12 runtime", () => {
    const legacy = listVmImageManifestEntries()[0]!;
    const approved = {
      ...legacy,
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

    const { binarySha256: _binarySha256, ...incompleteRuntime } = approved.machineRuntime;
    expect(isVmImageMachineConnectable({
      ...approved,
      machineRuntime: incompleteRuntime,
    } as never)).toBe(false);
  });

  test("requires a verification time for checked and approved machine stages", () => {
    const legacy = listVmImageManifestEntries()[0]!;
    const runtime = {
      readiness: "approved",
      cmuxCommit: "a".repeat(40),
      cmuxVersion: "0.1.0",
      binarySha256: "b".repeat(64),
      protocolVersion: 12,
      bootstrapGeneration: 1,
      architecture: "aarch64",
      supervisorVersion: "cmux-cloud-supervisor-v1",
      transport: "ssh-provider-stream",
      authentication: "ssh-edge-ticket",
    } as const;

    expect(isVmImageMachineConnectable({ ...legacy, machineRuntime: runtime } as never)).toBe(
      false,
    );
    expect(isVmImageMachineConnectable({
      ...legacy,
      machineRuntime: { ...runtime, verifiedAt: "not-a-timestamp" },
    } as never)).toBe(false);
  });

  test("uses manifest local defaults outside deployed runtimes", () => {
    expect(resolveVmImage("e2b", undefined, {})).toMatchObject({
      provider: "e2b",
      image: "cmuxd-ws:tooling-20260509f",
      imageVersion: "e2b-tooling-20260509f",
    });
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      provider: "freestyle",
      image: "sh-b3jqa6o88qe6l738dw9z",
      imageVersion: "freestyle-signedadmin-20260625b",
    });
    expect(imageUsesBakedFreestyleSignedAdmin("freestyle", "sh-b3jqa6o88qe6l738dw9z")).toBe(true);
  });

  test("daytona has no local default until a validated snapshot lands in the manifest", () => {
    expect(() => resolveVmImage("daytona", undefined, {})).toThrow(VmImageConfigError);
    expect(captureImageConfigError(() => resolveVmImage("daytona", undefined, {}))).toMatchObject({
      provider: "daytona",
      envVar: "DAYTONA_SANDBOX_SNAPSHOT",
      reason: "no local default image is recorded for daytona",
    });
  });

  test("daytona local dev resolves DAYTONA_SANDBOX_SNAPSHOT even when unmanifested", () => {
    expect(
      resolveVmImage("daytona", undefined, {
        DAYTONA_SANDBOX_SNAPSHOT: "cmuxd-ws-scratch",
      }),
    ).toMatchObject({
      provider: "daytona",
      image: "cmuxd-ws-scratch",
      imageVersion: null,
      manifestEntry: null,
    });
  });

  test("requires deployed env selectors", () => {
    expect(() =>
      resolveVmImage("freestyle", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "preview",
      }),
    ).toThrow(VmImageConfigError);
    expect(captureImageConfigError(() =>
      resolveVmImage("daytona", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "preview",
      }),
    )).toMatchObject({
      provider: "daytona",
      reason: "DAYTONA_SANDBOX_SNAPSHOT is required in deployed environments",
    });
  });

  test("rejects unknown deployed images", () => {
    expect(() =>
      resolveVmImage("e2b", "cmuxd-ws:unknown", {
        VERCEL: "1",
        VERCEL_ENV: "production",
      }),
    ).toThrow(VmImageConfigError);
  });

  test("resolves deployed env selectors through the manifest", () => {
    expect(
      resolveVmImage("e2b", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        E2B_CMUXD_WS_TEMPLATE: "cmuxd-ws:proxy-20260424a",
      }),
    ).toMatchObject({
      provider: "e2b",
      image: "cmuxd-ws:proxy-20260424a",
      imageVersion: "e2b-proxy-20260424a",
    });
  });

  test("permits unmanifested images only when explicitly allowed", () => {
    expect(
      resolveVmImage("freestyle", "scratch-image", {
        VERCEL: "1",
        VERCEL_ENV: "preview",
        CMUX_VM_ALLOW_UNMANIFESTED_IMAGES: "1",
      }),
    ).toMatchObject({
      provider: "freestyle",
      image: "scratch-image",
      imageVersion: null,
      manifestEntry: null,
    });
  });
});
