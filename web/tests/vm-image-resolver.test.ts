import { describe, expect, test } from "bun:test";
import {
  imageSignedAuthPublicKeySha256,
  imageSupportsSignedWebSocketAuth,
  resolveVmImage,
} from "../services/vms/images/resolver";
import { VmImageConfigError } from "../services/vms/errors";

describe("VM image resolver", () => {
  test("uses manifest local defaults outside deployed runtimes", () => {
    expect(resolveVmImage("e2b", undefined, {})).toMatchObject({
      provider: "e2b",
      image: "cmuxd-ws:tooling-20260509f",
      imageVersion: "e2b-tooling-20260509f",
    });
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      provider: "freestyle",
      image: "sh-6a3egjzxg8nfo52t21vs",
      imageVersion: "freestyle-signedauth-20260614d",
      manifestEntry: {
        features: {
          signedWebSocketAuth: true,
          signedAuthPublicKeySha256: "3e979ee9c381b40c49a868d511edb5002631355138ac1e29841f066b8aab09a5",
        },
      },
    });
    expect(imageSupportsSignedWebSocketAuth("freestyle", "sh-6a3egjzxg8nfo52t21vs")).toBe(true);
    expect(imageSignedAuthPublicKeySha256("freestyle", "sh-6a3egjzxg8nfo52t21vs")).toBe(
      "3e979ee9c381b40c49a868d511edb5002631355138ac1e29841f066b8aab09a5",
    );
  });

  test("requires deployed env selectors", () => {
    expect(() =>
      resolveVmImage("freestyle", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "preview",
      }),
    ).toThrow(VmImageConfigError);
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
