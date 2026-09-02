import { describe, expect, test } from "bun:test";
import {
  reportVmImageConfigError,
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
    expect(providerImageEnvKey("e2b")).toBe("E2B_CMUXD_WS_TEMPLATE");
    expect(providerImageEnvKey("e2b", "base")).toBe("E2B_CMUXD_WS_TEMPLATE");
    // No provider ships a desktop image today, so no provider has a distinct
    // `_IMAGE`-suffixed selector to split; the generic one serves both kinds.
    expect(providerImageEnvKey("e2b", "desktop")).toBe("E2B_CMUXD_WS_TEMPLATE");
    expect(providerImageEnvKey("freestyle", "desktop")).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
    expect(providerImageEnvKey("daytona", "desktop")).toBe("DAYTONA_SANDBOX_SNAPSHOT");
  });

  test("the kind env var resolves a manifest image of that kind", () => {
    expect(
      resolveVmImage("e2b", undefined, {
        ...deployed,
        E2B_CMUXD_WS_TEMPLATE: "cmux-devbox:devbox-20260828b",
      }, { kind: "base" }),
    ).toMatchObject({
      image: "cmux-devbox:devbox-20260828b",
      imageVersion: "e2b-devbox-20260828b",
      kind: "base",
    });
  });

  test("an explicitly requested image of the wrong kind still errors", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("e2b", "cmux-devbox:devbox-20260828b", deployed, { kind: "desktop" }));
    expect(err.reason).toMatch(/base image, not a desktop image/);
  });

  test("no provider ships a desktop image, so every desktop request fails closed", () => {
    // The desktop kind and its noVNC wrapper are kept as a seam for Freestyle
    // desktop support; until an image exists, the request must 503 with a
    // config error rather than silently serving a base machine.
    for (const provider of ["freestyle", "e2b", "daytona"] as const) {
      const err = captureImageConfigError(() =>
        resolveVmImage(provider, undefined, deployed, { kind: "desktop" }),
      );
      expect(err).toMatchObject({ provider, kind: "desktop", source: "default" });
    }
  });

  test("freestyle has no usable image until the devbox snapshot is re-baked on the public platform", () => {
    // The only freestyle manifest entry was baked against the retired
    // beta-api endpoint and carries validationStatus "unknown", so it is
    // neither a kind default nor a local-dev default. Creates fail closed.
    const err = captureImageConfigError(() => resolveVmImage("freestyle", undefined, deployed));
    expect(err).toMatchObject({
      provider: "freestyle",
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
      source: "env",
    });
    expect(captureImageConfigError(() => resolveVmImage("freestyle", undefined, {}))).toMatchObject({
      provider: "freestyle",
      reason: "no local default image is recorded for freestyle",
    });
    expect(listVmImageKinds("freestyle", deployed)).toEqual([]);
  });

  test("an operator-set freestyle snapshot still resolves, so a re-bake is env-only", () => {
    expect(
      resolveVmImage("freestyle", undefined, {
        ...deployed,
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-fb3dcf7b47894114889b10186626af5b",
      }),
    ).toMatchObject({
      provider: "freestyle",
      image: "sh-fb3dcf7b47894114889b10186626af5b",
      imageVersion: "freestyle-cmux-devbox-beta1",
    });
  });

  test("rejects unknown kinds with an actionable error", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("e2b", undefined, deployed, { kind: "gpu" as unknown as VmImageKind }),
    );
    expect(err).toMatchObject({ provider: "e2b", kind: "gpu", source: "request" });
    expect(reportVmImageConfigError(err, deployed)).toMatchObject({
      message: 'Cloud VM image kind "gpu" is not supported.',
      // Nothing is flagged defaultForKind and `deployed` sets no selector, so
      // no kind is currently servable.
      details: { imageRequested: false, kind: "gpu", source: "request", allowedKinds: [] },
    });
  });

  test("a kind with nothing configured names the env var and stays client-safe", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "desktop" }),
    );
    expect(err).toMatchObject({
      provider: "freestyle",
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
      kind: "desktop",
      source: "default",
      reason: "no desktop image is configured for freestyle: set FREESTYLE_SANDBOX_SNAPSHOT or record a desktop manifest default",
    });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.message).toBe("No desktop Cloud VM image is available in this environment.");
    expect(report.action).toContain("available: none");
    // Client-safe details name the kind and the source, never the env var or image ids.
    expect(report.details).toEqual({
      imageRequested: false,
      kind: "desktop",
      source: "default",
      allowedKinds: [],
    });
    expect(JSON.stringify(report.details)).not.toMatch(/FREESTYLE_|manifest\.json|sh-[a-z0-9]/);
    // The operator log carries what the response may not.
    expect(report.operator).toMatchObject({
      provider: "freestyle",
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
    });
  });

  test("client-requested unknown images stay strict and report imageRequested", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("e2b", "cmuxd-ws:unlisted", deployed),
    );
    expect(err).toMatchObject({ image: "cmuxd-ws:unlisted", source: "request" });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.details).toEqual({ imageRequested: true, kind: undefined, source: "request", allowedKinds: [] });
    expect(report.message).toBe("The requested Cloud VM image is not available in this environment.");
    expect(report.operator).toMatchObject({ image: "cmuxd-ws:unlisted" });
  });

  test("derives a kind for stored images and lists the kinds a provider can serve", () => {
    expect(vmImageKindFor("e2b", "cmux-devbox:devbox-20260828b")).toBe("base");
    expect(vmImageKindFor("daytona", "cmux-devbox-20260828b")).toBe("base");
    // No manifest kind and no `xfce`/`devbox` in the id: the heuristic says base.
    expect(vmImageKindFor("freestyle", "sh-fb3dcf7b47894114889b10186626af5b")).toBe("base");

    // Nothing is flagged defaultForKind, so a kind only resolves from an env selector.
    expect(listVmImageKinds("e2b", deployed)).toEqual([]);
    expect(listVmImageKinds("e2b", { ...deployed, E2B_CMUXD_WS_TEMPLATE: "cmux-devbox:devbox-20260828b" })).toEqual([
      { kind: "base", image: "cmux-devbox:devbox-20260828b" },
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
    // Production drifted once: the provider's image selector named an image the
    // manifest did not list, and every base open failed with imageRequested:
    // true even though the client sent no image. Operator config wins; only
    // client requests are strict.
    expect(
      resolveVmImage("e2b", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        E2B_CMUXD_WS_TEMPLATE: "cmuxd-ws:ops-override",
      }),
    ).toMatchObject({
      provider: "e2b",
      image: "cmuxd-ws:ops-override",
      imageVersion: null,
      manifestEntry: null,
      kind: "base",
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

describe("provider inference from explicit images", () => {
  test("a manifest image id uniquely owned by one provider infers that provider", () => {
    expect(inferVmProviderForImage("sh-fb3dcf7b47894114889b10186626af5b")).toBe("freestyle");
    expect(inferVmProviderForImage("cmuxd-ws:tooling-20260509f")).toBe("e2b");
    expect(inferVmProviderForImage("cmux-devbox-20260828b")).toBe("daytona");
  });

  test("manifest versions infer their provider too", () => {
    expect(inferVmProviderForImage("freestyle-cmux-devbox-beta1")).toBe("freestyle");
    expect(inferVmProviderForImage("e2b-proxy-20260424a")).toBe("e2b");
  });

  test("unknown or absent images infer nothing", () => {
    expect(inferVmProviderForImage("not-in-the-manifest")).toBeNull();
    expect(inferVmProviderForImage(undefined)).toBeNull();
    expect(inferVmProviderForImage("   ")).toBeNull();
  });
});
