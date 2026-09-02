import { describe, expect, test } from "bun:test";
import {
  reportVmImageConfigError,
  inferVmProviderForImage,
  listVmImageKinds,
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

// cmux's validated public-platform devbox (baked on cmux's Freestyle account):
// the manifest's base default. The manifest is the only source of truth for
// images; no env var selects or overrides one.
const validatedSnapshot = "sh-e4dc9393a82e4dfaaa8f90b01b0d247c";
const validatedVersion = "freestyle-cmux-devbox-20260902e";
// The desktop devbox from this PR: validated, listed under both kinds with one
// image id, but baked on another Freestyle account, so not a default until
// re-promoted under cmux's key.
const desktopSnapshot = "sh-1d66b9cad53a4811b5f63a4cae0b3faf";
const desktopVersion = "freestyle-cmux-devbox-20260902h";

describe("VM image resolver: request by kind", () => {
  const deployed = { VERCEL: "1", VERCEL_ENV: "production" };

  test("FREESTYLE_SANDBOX_SNAPSHOT is ignored: only the manifest decides", () => {
    // The env var used to select (and could override) the image. It no longer
    // exists as far as the resolver is concerned: a stale value naming another
    // manifest entry, or nothing in the manifest at all, changes nothing.
    for (const stale of ["sh-fb3dcf7b47894114889b10186626af5b", "sh-ops-override", ""]) {
      expect(
        resolveVmImage("freestyle", undefined, { ...deployed, FREESTYLE_SANDBOX_SNAPSHOT: stale }, { kind: "base" }),
      ).toMatchObject({ image: validatedSnapshot, imageVersion: validatedVersion, kind: "base" });
      expect(resolveVmImage("freestyle", undefined, { FREESTYLE_SANDBOX_SNAPSHOT: stale })).toMatchObject({
        image: validatedSnapshot,
        imageVersion: validatedVersion,
      });
    }
  });

  test("an explicitly requested image of the wrong kind still errors", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", validatedSnapshot, deployed, { kind: "desktop" }));
    expect(err.reason).toMatch(/base image, not a desktop image/);
  });

  test("no desktop default is recorded yet, so a desktop request fails closed", () => {
    // The desktop devbox is listed (validated) but not a default: it was baked
    // on another Freestyle account. Until it is re-promoted under cmux's key,
    // a desktop request must 503 with a config error rather than silently
    // serving a base machine.
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "desktop" }),
    );
    expect(err).toMatchObject({ provider: "freestyle", kind: "desktop", source: "default" });
  });

  test("the committed manifest default serves base machines", () => {
    // The manifest is the only source of truth: the entry flagged
    // defaultForKind is what every runtime serves, deployed or local, and a
    // request with neither image nor kind gets the base default too.
    expect(resolveVmImage("freestyle", undefined, deployed, { kind: "base" })).toMatchObject({
      provider: "freestyle",
      image: validatedSnapshot,
      imageVersion: validatedVersion,
      kind: "base",
    });
    expect(listVmImageKinds("freestyle", deployed)).toEqual([{ kind: "base", image: validatedSnapshot }]);
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      image: validatedSnapshot,
      imageVersion: validatedVersion,
    });
    expect(resolveVmImage("freestyle", undefined, deployed)).toMatchObject({
      image: validatedSnapshot,
      imageVersion: validatedVersion,
      kind: "base",
    });
  });

  test("an image listed under two kinds resolves to the entry of the requested kind", () => {
    // A client-requested image, or the env selector, naming the shared
    // desktop snapshot must not be rejected as "a desktop image, not a base image".
    expect(resolveVmImage("freestyle", desktopSnapshot, deployed, { kind: "base" })).toMatchObject({
      imageVersion: `${desktopVersion}-base`,
      kind: "base",
    });
    expect(resolveVmImage("freestyle", desktopSnapshot, deployed, { kind: "desktop" })).toMatchObject({
      imageVersion: desktopVersion,
      kind: "desktop",
    });
    expect(resolveVmImage("freestyle", desktopVersion, deployed, { kind: "desktop" })).toMatchObject({
      image: desktopSnapshot,
      kind: "desktop",
    });
    // Without a kind the first listing wins, and a stored image id reads as desktop.
    expect(vmImageKindFor("freestyle", desktopSnapshot)).toBe("desktop");
  });

  test("rejects unknown kinds with an actionable error", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "gpu" as unknown as VmImageKind }),
    );
    expect(err).toMatchObject({ provider: "freestyle", kind: "gpu", source: "request" });
    expect(reportVmImageConfigError(err, deployed)).toMatchObject({
      message: 'Cloud VM image kind "gpu" is not supported.',
      // The manifest's base default is servable even with no selector set.
      details: { imageRequested: false, kind: "gpu", source: "request", allowedKinds: ["base"] },
    });
  });

  test("a kind with no manifest default fails closed and stays client-safe", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "desktop" }),
    );
    expect(err).toMatchObject({
      provider: "freestyle",
      kind: "desktop",
      source: "default",
      reason: "no desktop image is recorded as the manifest default for freestyle: promote one (bun run devbox:promote -- freestyle)",
    });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.message).toBe("No desktop Cloud VM image is available in this environment.");
    expect(report.action).toContain("available: base");
    // Client-safe details name the kind and the source, never image ids or manifest wording.
    expect(report.details).toEqual({
      imageRequested: false,
      kind: "desktop",
      source: "default",
      allowedKinds: ["base"],
    });
    expect(JSON.stringify(report.details)).not.toMatch(/FREESTYLE_|manifest|sh-[a-z0-9]/);
    // The operator log carries what the response may not.
    expect(report.operator).toMatchObject({ provider: "freestyle", kind: "desktop" });
    expect(report.operator.allowedImages).toContain(validatedSnapshot);
  });

  test("client-requested unknown images stay strict and report imageRequested", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", "cmuxd-ws:unlisted", deployed),
    );
    expect(err).toMatchObject({ image: "cmuxd-ws:unlisted", source: "request" });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.details).toEqual({ imageRequested: true, kind: undefined, source: "request", allowedKinds: ["base"] });
    expect(report.message).toBe("The requested Cloud VM image is not available in this environment.");
    expect(report.operator).toMatchObject({ image: "cmuxd-ws:unlisted" });
  });

  test("derives a kind for stored images and lists the kinds a provider can serve", () => {
    // No manifest kind and no `xfce`/`devbox` in the id: the heuristic says base.
    expect(vmImageKindFor("freestyle", validatedSnapshot)).toBe("base");

    // The base default is flagged in the manifest; the retired beta entry never is.
    expect(listVmImageKinds("freestyle", deployed)).toEqual([{ kind: "base", image: validatedSnapshot }]);
    expect(listVmImageKinds("freestyle", deployed).map((entry) => entry.image)).not.toContain("sh-fb3dcf7b47894114889b10186626af5b");
  });
});

describe("VM image resolver", () => {
  test("local dev uses the manifest default", () => {
    // `bun dev` boots the same validated image production does, with no env
    // var to copy around.
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      provider: "freestyle",
      image: validatedSnapshot,
      imageVersion: validatedVersion,
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
