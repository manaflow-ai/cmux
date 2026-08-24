import { describe, expect, test } from "bun:test";
import {
  imageUsesBakedFreestyleSignedAdmin,
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
