import { describe, expect, test } from "bun:test";
import {
  reportVmImageConfigError,
  imageUsesBakedFreestyleSignedAdmin,
  inferVmProviderForImage,
  listVmImageKinds,
  providerImageEnvKey,
  resolveVmImage,
  vmImageKindFor,
  type VmImageKind,
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

describe("VM image resolver: request by kind", () => {
  const deployed = { VERCEL: "1", VERCEL_ENV: "production" };

  test("desktop images get their own env selector; single-variable providers share one", () => {
    expect(providerImageEnvKey("blaxel")).toBe("BLAXEL_SANDBOX_IMAGE");
    expect(providerImageEnvKey("blaxel", "base")).toBe("BLAXEL_SANDBOX_IMAGE");
    expect(providerImageEnvKey("blaxel", "desktop")).toBe("BLAXEL_SANDBOX_DESKTOP_IMAGE");
    expect(providerImageEnvKey("e2b", "desktop")).toBe("E2B_CMUXD_WS_TEMPLATE");
    expect(providerImageEnvKey("freestyle", "desktop")).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
  });

  test("kind env var wins over the manifest kind default", () => {
    expect(
      resolveVmImage("blaxel", undefined, {
        ...deployed,
        BLAXEL_SANDBOX_DESKTOP_IMAGE: "blaxel/xfce-vnc:latest",
        BLAXEL_SANDBOX_IMAGE: "blaxel/base-image:latest",
      }, { kind: "desktop" }),
    ).toMatchObject({
      image: "blaxel/xfce-vnc:latest",
      imageVersion: "blaxel-bootstrap-20260820a",
      kind: "desktop",
    });
    expect(
      resolveVmImage("blaxel", undefined, {
        ...deployed,
        BLAXEL_SANDBOX_DESKTOP_IMAGE: "blaxel/xfce-vnc:latest",
        BLAXEL_SANDBOX_IMAGE: "blaxel/base-image:latest",
      }, { kind: "base" }),
    ).toMatchObject({ image: "blaxel/base-image:latest", imageVersion: null, kind: "base" });
  });

  test("deployed runtimes fall back to the manifest kind default instead of throwing", () => {
    // The nightly app's `vm base open` with no image and nothing configured for
    // desktop used to 503; now the manifest default desktop image serves it.
    expect(resolveVmImage("blaxel", undefined, deployed, { kind: "desktop" })).toMatchObject({
      image: "sandbox/cmux-devbox:latest",
      imageVersion: "blaxel-cmux-devbox-20260826a",
      kind: "desktop",
    });
    // Without a kind, the legacy contract still requires the env selector.
    expect(captureImageConfigError(() => resolveVmImage("blaxel", undefined, deployed))).toMatchObject({
      envVar: "BLAXEL_SANDBOX_IMAGE",
      source: "env",
    });
  });

  test("the generic env selector serves a desktop request when it names a desktop image", () => {
    expect(
      resolveVmImage("blaxel", undefined, {
        ...deployed,
        BLAXEL_SANDBOX_IMAGE: "blaxel/xfce-vnc:latest",
      }, { kind: "desktop" }),
    ).toMatchObject({ image: "blaxel/xfce-vnc:latest", kind: "desktop" });
  });

  test("an explicit image overrides kind, but must match the kind it claims", () => {
    expect(
      resolveVmImage("blaxel", "blaxel/xfce-vnc:latest", deployed, { kind: "desktop" }),
    ).toMatchObject({ image: "blaxel/xfce-vnc:latest", kind: "desktop" });
    expect(captureImageConfigError(() =>
      resolveVmImage("blaxel", "blaxel/xfce-vnc:latest", deployed, { kind: "base" }),
    )).toMatchObject({
      image: "blaxel/xfce-vnc:latest",
      kind: "base",
      source: "request",
      reason: "blaxel/xfce-vnc:latest is a desktop image, not a base image",
    });
  });

  test("rejects unknown kinds with an actionable error", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("blaxel", undefined, deployed, { kind: "gpu" as unknown as VmImageKind }),
    );
    expect(err).toMatchObject({ provider: "blaxel", kind: "gpu", source: "request" });
    expect(err.allowedImages).toEqual(["sandbox/cmux-devbox:latest", "blaxel/xfce-vnc:latest"]);
    expect(reportVmImageConfigError(err, deployed)).toMatchObject({
      message: 'Cloud VM image kind "gpu" is not supported.',
      details: { imageRequested: false, kind: "gpu", source: "request", allowedKinds: ["desktop"] },
    });
  });

  test("a kind with nothing configured names the env var and the allowed images", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("blaxel", undefined, deployed, { kind: "base" }),
    );
    expect(err).toMatchObject({
      provider: "blaxel",
      envVar: "BLAXEL_SANDBOX_IMAGE",
      kind: "base",
      source: "default",
      reason: "no base image is configured for blaxel: set BLAXEL_SANDBOX_IMAGE or record a base manifest default",
    });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.message).toBe("No base Cloud VM image is available in this environment.");
    expect(report.action).toContain("available: desktop");
    // Client-safe details name the kind and the source, never the env var or image ids.
    expect(report.details).toEqual({
      imageRequested: false,
      kind: "base",
      source: "default",
      allowedKinds: ["desktop"],
    });
    expect(JSON.stringify(report.details)).not.toMatch(/BLAXEL_|manifest\.json|cmux-devbox/);
    // The operator log carries what the response may not.
    expect(report.operator).toMatchObject({
      provider: "blaxel",
      envVar: "BLAXEL_SANDBOX_IMAGE",
      allowedImages: ["sandbox/cmux-devbox:latest", "blaxel/xfce-vnc:latest"],
    });
  });

  test("client-requested unknown images stay strict and report imageRequested", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("blaxel", "blaxel/base-image:latest", deployed),
    );
    expect(err).toMatchObject({ image: "blaxel/base-image:latest", source: "request" });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.details).toEqual({ imageRequested: true, kind: undefined, source: "request", allowedKinds: ["desktop"] });
    expect(report.message).toBe("The requested Cloud VM image is not available in this environment.");
    expect(report.action).toContain("`kind`: desktop");
    expect(report.operator).toMatchObject({ image: "blaxel/base-image:latest", allowedImages: ["sandbox/cmux-devbox:latest", "blaxel/xfce-vnc:latest"] });
  });

  test("local dev serves a kind from the local default only when the kinds agree", () => {
    expect(resolveVmImage("blaxel", undefined, {}, { kind: "desktop" })).toMatchObject({
      image: "sandbox/cmux-devbox:latest",
      kind: "desktop",
    });
    expect(resolveVmImage("freestyle", undefined, {}, { kind: "base" })).toMatchObject({
      image: "sh-b3jqa6o88qe6l738dw9z",
      kind: "base",
    });
    expect(() => resolveVmImage("freestyle", undefined, {}, { kind: "desktop" })).toThrow(VmImageConfigError);
  });

  test("derives a kind for stored images and lists the kinds a provider can serve", () => {
    expect(vmImageKindFor("blaxel", "sandbox/cmux-devbox:latest")).toBe("desktop");
    expect(vmImageKindFor("blaxel", "blaxel/xfce-vnc:latest")).toBe("desktop");
    expect(vmImageKindFor("blaxel", "blaxel/base-image:latest")).toBe("base");
    expect(vmImageKindFor("freestyle", "sh-b3jqa6o88qe6l738dw9z")).toBe("base");

    expect(listVmImageKinds("blaxel", deployed)).toEqual([
      { kind: "desktop", image: "sandbox/cmux-devbox:latest" },
    ]);
    expect(listVmImageKinds("blaxel", { ...deployed, BLAXEL_SANDBOX_IMAGE: "blaxel/base-image:latest" })).toEqual([
      { kind: "desktop", image: "sandbox/cmux-devbox:latest" },
      { kind: "base", image: "blaxel/base-image:latest" },
    ]);
    expect(listVmImageKinds("freestyle", {})).toEqual([
      { kind: "base", image: "sh-b3jqa6o88qe6l738dw9z" },
    ]);
  });
});

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

  test("accepts an env-configured image that is missing from the manifest", () => {
    // Production drifted: BLAXEL_SANDBOX_IMAGE named an image the manifest did not
    // list, and every base open failed with imageRequested: true even though the
    // client sent no image. Operator config wins; only client requests are strict.
    expect(
      resolveVmImage("blaxel", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        BLAXEL_SANDBOX_IMAGE: "blaxel/base-image:latest",
      }),
    ).toMatchObject({
      provider: "blaxel",
      image: "blaxel/base-image:latest",
      imageVersion: null,
      manifestEntry: null,
      kind: "base",
    });
    expect(
      resolveVmImage("blaxel", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        BLAXEL_SANDBOX_DESKTOP_IMAGE: "sandbox/cmux-devbox:next",
      }, { kind: "desktop" }),
    ).toMatchObject({ image: "sandbox/cmux-devbox:next", imageVersion: null, kind: "desktop" });
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

describe("provider inference from explicit images", () => {
  test("a manifest image id uniquely owned by one provider infers that provider", () => {
    expect(inferVmProviderForImage("blaxel/xfce-vnc:latest")).toBe("blaxel");
    expect(inferVmProviderForImage("sandbox/cmux-devbox:latest")).toBe("blaxel");
    expect(inferVmProviderForImage("sh-6ch5p9k23xrcx24056n8")).toBe("freestyle");
    expect(inferVmProviderForImage("cmuxd-ws:tooling-20260509f")).toBe("e2b");
  });

  test("manifest versions infer their provider too", () => {
    expect(inferVmProviderForImage("blaxel-bootstrap-20260820a")).toBe("blaxel");
    expect(inferVmProviderForImage("freestyle-rpclease-20260502a")).toBe("freestyle");
  });

  test("unknown or absent images infer nothing", () => {
    expect(inferVmProviderForImage("not-in-the-manifest")).toBeNull();
    expect(inferVmProviderForImage(undefined)).toBeNull();
    expect(inferVmProviderForImage("   ")).toBeNull();
  });
});
