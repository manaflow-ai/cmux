import { describe, expect, test } from "bun:test";
import {
  findVmImageKindDefault,
  reportVmImageConfigError,
  inferVmProviderForImage,
  listVmImageKinds,
  listVmImageSizes,
  resolveVmImage,
  vmImageKindFor,
  type VmImageKind,
} from "../services/vms/images/resolver";
import { VM_IMAGE_SIZE_NAMES, pickVmImageSizeForMemory, vmImageSize } from "../services/vms/images/sizes";
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

// The committed manifest default: the `freestyle-cmux-devbox-20260903b` ladder
// (baked, instance-bound cmux-tui daemon plus the coderouter edge changes),
// one snapshot per Freestyle size, listed under both kinds (a desktop image is
// a superset of a base one, so the same snapshot id serves both; the base
// listing's version carries a `-base` suffix). The manifest is the only source
// of truth for images; no env var selects or overrides one, and the plan's
// memory picks the size.
const ladderVersion = "freestyle-cmux-devbox-20260903b";
const ladder = {
  sm: "sh-36ede74d2c1845d2a9fd3453b0bff404",
  md: "sh-3d0d4f89f55b4c749377121f4ec1426c",
  lg: "sh-e66dfcdab7c0410ba8de295cee199bff",
  xl: "sh-e11d652875604b25b5832d4943d893a7",
  "2xl": "sh-dedf3965adfd46a6954744f4d0163b5c",
} as const;
// cmux's validated pre-ladder public-platform devbox: still listed (base only,
// size-less) so stored rows and explicit requests keep resolving, no longer a
// default.
const legacySnapshot = "sh-940ec3bc46224c019e5e8d9a97053293";
const legacyVersion = "freestyle-cmux-devbox-20260902c";
// The pre-ladder desktop devbox: validated, listed under both kinds with one
// image id, never a default.
const legacyDesktopSnapshot = "sh-1d66b9cad53a4811b5f63a4cae0b3faf";
const legacyDesktopVersion = "freestyle-cmux-devbox-20260902h";
// The retired beta-endpoint bake: listed for history, never a default.
const retiredBetaSnapshot = "sh-fb3dcf7b47894114889b10186626af5b";

describe("VM image resolver: request by kind", () => {
  const deployed = { VERCEL: "1", VERCEL_ENV: "production" };

  test("FREESTYLE_SANDBOX_SNAPSHOT is ignored: only the manifest decides", () => {
    // The env var used to select (and could override) the image. It no longer
    // exists as far as the resolver is concerned: a stale value naming another
    // manifest entry, or nothing in the manifest at all, changes nothing.
    for (const stale of [retiredBetaSnapshot, legacySnapshot, "sh-ops-override", ""]) {
      expect(
        resolveVmImage("freestyle", undefined, { ...deployed, FREESTYLE_SANDBOX_SNAPSHOT: stale }, { kind: "base" }),
      ).toMatchObject({ image: ladder.sm, imageVersion: `${ladderVersion}-sm-base`, kind: "base" });
      expect(
        resolveVmImage("freestyle", undefined, { ...deployed, FREESTYLE_SANDBOX_SNAPSHOT: stale }, { kind: "desktop" }),
      ).toMatchObject({ image: ladder.sm, imageVersion: `${ladderVersion}-sm`, kind: "desktop" });
      expect(resolveVmImage("freestyle", undefined, { FREESTYLE_SANDBOX_SNAPSHOT: stale })).toMatchObject({
        image: ladder.sm,
        imageVersion: `${ladderVersion}-sm-base`,
      });
    }
  });

  test("an explicitly requested image of the wrong kind still errors", () => {
    // The legacy public-platform devbox is listed under base only.
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", legacySnapshot, deployed, { kind: "desktop" }));
    expect(err.reason).toMatch(/base image, not a desktop image/);
  });

  test("the committed manifest ladder serves both kinds; no memory means the smallest size", () => {
    // The manifest is the only source of truth: the entries flagged
    // defaultForKind are what every runtime serves, deployed or local. With no
    // `memoryMb` the resolver picks the smallest sized default (the documented
    // rule), and a request with neither image nor kind gets the base one.
    expect(resolveVmImage("freestyle", undefined, deployed, { kind: "base" })).toMatchObject({
      provider: "freestyle",
      image: ladder.sm,
      imageVersion: `${ladderVersion}-sm-base`,
      kind: "base",
      size: vmImageSize("sm"),
    });
    expect(resolveVmImage("freestyle", undefined, deployed, { kind: "desktop" })).toMatchObject({
      provider: "freestyle",
      image: ladder.sm,
      imageVersion: `${ladderVersion}-sm`,
      kind: "desktop",
      size: vmImageSize("sm"),
    });
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      image: ladder.sm,
      imageVersion: `${ladderVersion}-sm-base`,
      kind: "base",
    });
    expect(resolveVmImage("freestyle", undefined, deployed)).toMatchObject({
      image: ladder.sm,
      imageVersion: `${ladderVersion}-sm-base`,
      kind: "base",
    });
    expect(listVmImageKinds("freestyle", deployed)).toEqual([
      { kind: "desktop", image: ladder.sm, size: vmImageSize("sm") },
      { kind: "base", image: ladder.sm, size: vmImageSize("sm") },
    ]);
  });

  test("the plan's memory picks the smallest ladder size that fits, for both kinds", () => {
    // One snapshot per size: the machine boots at its shape with nothing to
    // resize. Desktop and base share the snapshot id per size and differ only
    // in the manifest version (and kind).
    const expectations: Array<[number, keyof typeof ladder]> = [
      [512, "sm"],
      [4096, "sm"],
      [4097, "md"],
      [8192, "md"],
      [16384, "lg"],
      // cmux's paid plan machine (20 GiB) is between lg and xl: it boots xl.
      [20480, "xl"],
      [24576, "xl"],
      [32768, "xl"],
      [65536, "2xl"],
    ];
    for (const [memoryMb, sizeName] of expectations) {
      expect(pickVmImageSizeForMemory(memoryMb)?.name).toBe(sizeName);
      expect(resolveVmImage("freestyle", undefined, deployed, { kind: "base", memoryMb })).toMatchObject({
        image: ladder[sizeName],
        imageVersion: `${ladderVersion}-${sizeName}-base`,
        kind: "base",
        size: vmImageSize(sizeName),
      });
      expect(resolveVmImage("freestyle", undefined, deployed, { kind: "desktop", memoryMb })).toMatchObject({
        image: ladder[sizeName],
        imageVersion: `${ladderVersion}-${sizeName}`,
        kind: "desktop",
        size: vmImageSize(sizeName),
      });
      expect(resolveVmImage("freestyle", undefined, {}, { memoryMb })).toMatchObject({
        image: ladder[sizeName],
        kind: "base",
      });
    }
    // Both kinds offer the whole ladder, smallest first.
    for (const kind of ["desktop", "base"] as const) {
      expect(listVmImageSizes("freestyle", kind).map((size) => size.name)).toEqual([...VM_IMAGE_SIZE_NAMES]);
      expect(findVmImageKindDefault("freestyle", kind, 20480)?.size?.name).toBe("xl");
    }
    expect(listVmImageKinds("freestyle", deployed, { memoryMb: 20480 })).toEqual([
      { kind: "desktop", image: ladder.xl, size: vmImageSize("xl") },
      { kind: "base", image: ladder.xl, size: vmImageSize("xl") },
    ]);
  });

  test("a memory above the ladder fails closed with the sizes the manifest offers", () => {
    // Nothing on the ladder has 128 GiB: the resolver must not silently serve
    // the largest snapshot (the machine would boot smaller than the plan sold).
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "desktop", memoryMb: 131072 }),
    );
    expect(err).toMatchObject({ provider: "freestyle", kind: "desktop", source: "default" });
    expect(err.reason).toBe(
      "no desktop image size fits 131072 MiB for freestyle: the manifest offers sm (4096 MiB), md (8192 MiB), lg (16384 MiB), xl (32768 MiB), 2xl (65536 MiB)",
    );
    expect(findVmImageKindDefault("freestyle", "base", 65537)).toBeNull();

    const report = reportVmImageConfigError(err, deployed);
    expect(report.message).toBe("No desktop Cloud VM image is available in this environment.");
    // Client-safe details name the kind and the source, never image ids,
    // sizes, or manifest wording. `allowedKinds` is what the provider serves
    // at its smallest size, so both kinds are still offered.
    expect(report.details).toEqual({
      imageRequested: false,
      kind: "desktop",
      source: "default",
      allowedKinds: ["desktop", "base"],
    });
    expect(JSON.stringify(report.details)).not.toMatch(/FREESTYLE_|manifest|sh-[a-z0-9]|MiB/);
    // The operator log carries what the response may not.
    expect(report.operator).toMatchObject({ provider: "freestyle", kind: "desktop", reason: err.reason });
    expect(report.operator.allowedImages).toContain(ladder.sm);
  });

  test("an image listed under two kinds resolves to the entry of the requested kind", () => {
    // A client-requested image naming a snapshot shared by both kinds must not
    // be rejected as "a desktop image, not a base image".
    for (const [sizeName, snapshot] of Object.entries(ladder) as Array<[keyof typeof ladder, string]>) {
      expect(resolveVmImage("freestyle", snapshot, deployed, { kind: "base" })).toMatchObject({
        imageVersion: `${ladderVersion}-${sizeName}-base`,
        kind: "base",
        size: vmImageSize(sizeName),
      });
      expect(resolveVmImage("freestyle", snapshot, deployed, { kind: "desktop" })).toMatchObject({
        imageVersion: `${ladderVersion}-${sizeName}`,
        kind: "desktop",
        size: vmImageSize(sizeName),
      });
      // An explicit image pins its own size: the plan's memory does not re-pick it.
      expect(resolveVmImage("freestyle", snapshot, deployed, { kind: "base", memoryMb: 65536 })).toMatchObject({
        image: snapshot,
        size: vmImageSize(sizeName),
      });
    }
    expect(resolveVmImage("freestyle", `${ladderVersion}-lg`, deployed, { kind: "desktop" })).toMatchObject({
      image: ladder.lg,
      kind: "desktop",
    });
    // The pre-ladder shared desktop devbox behaves the same way.
    expect(resolveVmImage("freestyle", legacyDesktopSnapshot, deployed, { kind: "base" })).toMatchObject({
      imageVersion: `${legacyDesktopVersion}-base`,
      kind: "base",
      size: null,
    });
    expect(resolveVmImage("freestyle", legacyDesktopVersion, deployed, { kind: "desktop" })).toMatchObject({
      image: legacyDesktopSnapshot,
      kind: "desktop",
    });
    // Without a kind the first listing wins, and a stored image id reads as desktop.
    expect(vmImageKindFor("freestyle", ladder.sm)).toBe("desktop");
    expect(vmImageKindFor("freestyle", legacyDesktopSnapshot)).toBe("desktop");
  });

  test("rejects unknown kinds with an actionable error", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", undefined, deployed, { kind: "gpu" as unknown as VmImageKind }),
    );
    expect(err).toMatchObject({ provider: "freestyle", kind: "gpu", source: "request" });
    expect(reportVmImageConfigError(err, deployed)).toMatchObject({
      message: 'Cloud VM image kind "gpu" is not supported.',
      // Both manifest ladders are servable even with no selector set.
      details: { imageRequested: false, kind: "gpu", source: "request", allowedKinds: ["desktop", "base"] },
    });
  });

  test("client-requested unknown images stay strict and report imageRequested", () => {
    const err = captureImageConfigError(() =>
      resolveVmImage("freestyle", "cmuxd-ws:unlisted", deployed),
    );
    expect(err).toMatchObject({ image: "cmuxd-ws:unlisted", source: "request" });
    const report = reportVmImageConfigError(err, deployed);
    expect(report.details).toEqual({
      imageRequested: true,
      kind: undefined,
      source: "request",
      allowedKinds: ["desktop", "base"],
    });
    expect(report.message).toBe("The requested Cloud VM image is not available in this environment.");
    expect(report.action).toContain("kind`: desktop, base");
    expect(report.operator).toMatchObject({ image: "cmuxd-ws:unlisted" });
  });

  test("derives a kind for stored images and lists the kinds a provider can serve", () => {
    // The legacy public-platform devbox declares kind base in the manifest.
    expect(vmImageKindFor("freestyle", legacySnapshot)).toBe("base");
    // No manifest entry and no `xfce`/`devbox` in the id: the heuristic says base.
    expect(vmImageKindFor("freestyle", "sh-never-listed")).toBe("base");
    expect(vmImageKindFor("freestyle", "cmux-xfce:custom")).toBe("desktop");

    // Only the ladder is flagged default; the legacy bakes and the retired
    // beta entry never are.
    const served = listVmImageKinds("freestyle", deployed).map((entry) => entry.image);
    expect(served).toEqual([ladder.sm, ladder.sm]);
    expect(served).not.toContain(retiredBetaSnapshot);
    expect(served).not.toContain(legacySnapshot);
    expect(served).not.toContain(legacyDesktopSnapshot);
  });
});

describe("VM image resolver", () => {
  test("local dev uses the manifest default", () => {
    // `bun dev` boots the same ladder production does, with no env var to
    // copy around; at the paid plan's memory that is the xl snapshot.
    expect(resolveVmImage("freestyle", undefined, {})).toMatchObject({
      provider: "freestyle",
      image: ladder.sm,
      imageVersion: `${ladderVersion}-sm-base`,
    });
    expect(resolveVmImage("freestyle", undefined, {}, { memoryMb: 20480 })).toMatchObject({
      provider: "freestyle",
      image: ladder.xl,
      imageVersion: `${ladderVersion}-xl-base`,
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
      size: null,
    });
  });
});

describe("provider inference from explicit images", () => {
  test("a manifest image id infers its provider", () => {
    expect(inferVmProviderForImage(ladder.xl)).toBe("freestyle");
    expect(inferVmProviderForImage(legacySnapshot)).toBe("freestyle");
  });

  test("manifest versions infer their provider too", () => {
    expect(inferVmProviderForImage(`${ladderVersion}-xl-base`)).toBe("freestyle");
    expect(inferVmProviderForImage(legacyVersion)).toBe("freestyle");
  });

  test("unknown or absent images infer nothing", () => {
    expect(inferVmProviderForImage("not-in-the-manifest")).toBeNull();
    expect(inferVmProviderForImage(undefined)).toBeNull();
    expect(inferVmProviderForImage("   ")).toBeNull();
  });
});
