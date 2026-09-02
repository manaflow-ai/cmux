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

const validatedSnapshot = "sh-940ec3bc46224c019e5e8d9a97053293";
const validatedVersion = "freestyle-cmux-devbox-20260902c";

describe("VM image resolver: request by kind", () => {
  const deployed = { VERCEL: "1", VERCEL_ENV: "production" };

  test("desktop images get their own env selector; single-variable providers share one", () => {
    expect(providerImageEnvKey("freestyle")).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
    expect(providerImageEnvKey("freestyle", "base")).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
    // Freestyle ships no desktop image today, so it has no distinct
    // `_IMAGE`-suffixed selector to split; the generic one serves both kinds.
    expect(providerImageEnvKey("freestyle", "desktop")).toBe("FREESTYLE_SANDBOX_SNAPSHOT");
  });

  test("the kind env var resolves a manifest image of that kind", () => {
    expect(
      resolveVmImage("freestyle", undefined, {
        ...deployed,
        FREESTYLE_SANDBOX_SNAPSHOT: validatedSnapshot,
      }, { kind: "base" }),
    ).toMatchObject({
      image: validatedSnapshot,
      imageVersion: validatedVersion,
      kind: "base",
    });
  });

  test("an explicitly requested image of the wrong kind still errors", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", validatedSnapshot, deployed, { kind: "desktop" }));
    expect(err.reason).toMatch(/base image, not a desktop image/);
  });

  test("freestyle ships no desktop image, so every desktop request fails closed", () => {
    // The desktop kind and its noVNC wrapper are kept as a seam for Freestyle
    // desktop support; until an image exists, the request must 503 with a
    // config error rather than silently serving a base machine.
    for (const provider of ["freestyle"] as const) {
      const err = captureImageConfigError(() =>
        resolveVmImage(provider, undefined, deployed, { kind: "desktop" }),
      );
      expect(err).toMatchObject({ provider, kind: "desktop", source: "default" });
    }
  });

  test("freestyle resolves only through its env selector, like every other provider", () => {
    // The validated public-platform devbox entry is neither a kind default
    // nor a local-dev default, so a deployment must set
    // FREESTYLE_SANDBOX_SNAPSHOT explicitly; nothing is served silently.
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

  test("the validated public-platform devbox snapshot resolves from the env selector", () => {
    const env = { ...deployed, FREESTYLE_SANDBOX_SNAPSHOT: validatedSnapshot };
    expect(resolveVmImage("freestyle", undefined, env)).toMatchObject({
      provider: "freestyle",
      image: validatedSnapshot,
      imageVersion: validatedVersion,
    });
    expect(listVmImageKinds("freestyle", env)).toEqual([
      { kind: "base", image: validatedSnapshot },
    ]);
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
      resolveVmImage("freestyle", undefined, deployed, { kind: "gpu" as unknown as VmImageKind }),
    );
    expect(err).toMatchObject({ provider: "freestyle", kind: "gpu", source: "request" });
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
      resolveVmImage("freestyle", "cmuxd-ws:unlisted", deployed),
    );
    expect(err).toMatchObject({ image: "cmuxd-ws:unlisted", source: "request" });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.details).toEqual({ imageRequested: true, kind: undefined, source: "request", allowedKinds: [] });
    expect(report.message).toBe("The requested Cloud VM image is not available in this environment.");
    expect(report.operator).toMatchObject({ image: "cmuxd-ws:unlisted" });
  });

  test("derives a kind for stored images and lists the kinds a provider can serve", () => {
    // No manifest kind and no `xfce`/`devbox` in the id: the heuristic says base.
    expect(vmImageKindFor("freestyle", validatedSnapshot)).toBe("base");

    // Nothing is flagged defaultForKind, so a kind only resolves from an env selector.
    expect(listVmImageKinds("freestyle", deployed)).toEqual([]);
    expect(listVmImageKinds("freestyle", { ...deployed, FREESTYLE_SANDBOX_SNAPSHOT: validatedSnapshot })).toEqual([
      { kind: "base", image: validatedSnapshot },
    ]);
  });
});

describe("VM image resolver", () => {
  test("freestyle has no local default until an operator selects one", () => {
    // The validated entry remains defaultForLocalDev:false, so local dev fails
    // closed rather than silently booting a paid provider image.
    expect(() => resolveVmImage("freestyle", undefined, {})).toThrow(VmImageConfigError);
    expect(captureImageConfigError(() => resolveVmImage("freestyle", undefined, {}))).toMatchObject({
      provider: "freestyle",
      envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
      reason: "no local default image is recorded for freestyle",
    });
  });

  test("local dev resolves FREESTYLE_SANDBOX_SNAPSHOT even when unmanifested", () => {
    expect(
      resolveVmImage("freestyle", undefined, {
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-scratch",
      }),
    ).toMatchObject({
      provider: "freestyle",
      image: "sh-scratch",
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
      resolveVmImage("freestyle", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "preview",
      }),
    )).toMatchObject({
      provider: "freestyle",
      reason: "FREESTYLE_SANDBOX_SNAPSHOT is required in deployed environments",
    });
  });

  test("rejects unknown deployed images", () => {
    expect(() =>
      resolveVmImage("freestyle", "sh-unknown", {
        VERCEL: "1",
        VERCEL_ENV: "production",
      }),
    ).toThrow(VmImageConfigError);
  });

  test("resolves deployed env selectors through the manifest", () => {
    expect(
      resolveVmImage("freestyle", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        FREESTYLE_SANDBOX_SNAPSHOT: validatedSnapshot,
      }),
    ).toMatchObject({
      provider: "freestyle",
      image: validatedSnapshot,
      imageVersion: validatedVersion,
    });
  });

  test("accepts an env-configured image that is missing from the manifest", () => {
    // Production drifted once: the provider's image selector named an image the
    // manifest did not list, and every base open failed with imageRequested:
    // true even though the client sent no image. Operator config wins; only
    // client requests are strict.
    expect(
      resolveVmImage("freestyle", undefined, {
        VERCEL: "1",
        VERCEL_ENV: "production",
        FREESTYLE_SANDBOX_SNAPSHOT: "sh-ops-override",
      }),
    ).toMatchObject({
      provider: "freestyle",
      image: "sh-ops-override",
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
  test("a manifest image id infers its provider", () => {
    expect(inferVmProviderForImage(validatedSnapshot)).toBe("freestyle");
  });

  test("manifest versions infer their provider too", () => {
    expect(inferVmProviderForImage(validatedVersion)).toBe("freestyle");
  });

  test("unknown or absent images infer nothing", () => {
    expect(inferVmProviderForImage("not-in-the-manifest")).toBeNull();
    expect(inferVmProviderForImage(undefined)).toBeNull();
    expect(inferVmProviderForImage("   ")).toBeNull();
  });
});
