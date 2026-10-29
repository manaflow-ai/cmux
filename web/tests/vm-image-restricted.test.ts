import { describe, expect, mock, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import realManifest from "../services/vms/images/manifest.json";

// A restricted (test) manifest image: never a default, and only a caller whose
// Stack user id is in CMUX_VM_RESTRICTED_IMAGE_USER_IDS may create a machine
// on it by id. Everyone else gets the same refusal as an unknown id. This is
// how a Move to Cloud proof machine boots a candidate devbox image without
// promoting it (cx-rppd.14).

const RESTRICTED_ID = "sh-restricted-test-image";
const restrictedEntry = {
  ...realManifest.images.find((entry) => (entry as { defaultForKind?: boolean }).defaultForKind && (entry as { kind?: string }).kind === "desktop")!,
  version: "freestyle-cmux-devbox-restricted-test",
  imageId: RESTRICTED_ID,
  defaultForKind: false,
  restricted: true,
};
// The same image listed again under the other kind without the flag: the
// unrestricted twin must not open it.
const unrestrictedTwin = { ...restrictedEntry, version: "freestyle-cmux-devbox-restricted-test-base", kind: "base", restricted: undefined };
mock.module("../services/vms/images/manifest.json", () => ({
  default: { ...realManifest, images: [...realManifest.images, restrictedEntry, unrestrictedTwin] },
}));

const { findVmImageKindDefault, listVmImageKindDefaults, resolveVmImage, vmRestrictedImageAllowed } = await import("../services/vms/images/resolver");
const { VmImageConfigError } = await import("../services/vms/errors");
const { imageManifestProblems } = await import("../scripts/devbox-image-common");

const deployed = { VERCEL_ENV: "production", NODE_ENV: "production" };
const allow = (ids: string) => ({ ...deployed, CMUX_VM_RESTRICTED_IMAGE_USER_IDS: ids });

function refusal(fn: () => unknown): string {
  try {
    fn();
  } catch (error) {
    if (error instanceof VmImageConfigError) return error.reason;
    throw error;
  }
  throw new Error("expected a refusal");
}

describe("restricted manifest images", () => {
  test("only an allowlisted caller may request one by id", () => {
    const selection = resolveVmImage("freestyle", RESTRICTED_ID, allow("user-other, user-leo"), { callerUserId: "user-leo" });
    expect(selection.image).toBe(RESTRICTED_ID);
    expect(selection.manifestEntry?.restricted).toBe(true);
    // By version too.
    expect(resolveVmImage("freestyle", restrictedEntry.version, allow("user-leo"), { callerUserId: "user-leo" }).image).toBe(RESTRICTED_ID);
  });

  test("anyone else gets the unknown-image refusal, including with no allowlist or no caller", () => {
    const unknown = refusal(() => resolveVmImage("freestyle", "sh-not-in-manifest", deployed, { callerUserId: "user-leo" }));
    expect(refusal(() => resolveVmImage("freestyle", RESTRICTED_ID, allow("user-leo"), { callerUserId: "user-mallory" }))).toBe(
      unknown.replace("sh-not-in-manifest", RESTRICTED_ID),
    );
    expect(refusal(() => resolveVmImage("freestyle", RESTRICTED_ID, deployed, { callerUserId: "user-leo" }))).toContain("not listed");
    expect(refusal(() => resolveVmImage("freestyle", RESTRICTED_ID, allow("user-leo"), {}))).toContain("not listed");
    // Even where unmanifested images are allowed (local dev), the entry stays gated.
    expect(refusal(() => resolveVmImage("freestyle", RESTRICTED_ID, { CMUX_VM_ALLOW_UNMANIFESTED_IMAGES: "1" }, { callerUserId: "user-leo" }))).toContain("not listed");
  });

  test("an unrestricted twin of the same image does not open it", () => {
    expect(refusal(() => resolveVmImage("freestyle", RESTRICTED_ID, allow("user-leo"), { kind: "base", callerUserId: "user-mallory" }))).toContain("not listed");
    expect(resolveVmImage("freestyle", RESTRICTED_ID, allow("user-leo"), { kind: "base", callerUserId: "user-leo" }).image).toBe(RESTRICTED_ID);
  });

  test("both create paths hand the authenticated user to the resolver", () => {
    const read = (file: string) => readFileSync(path.join(import.meta.dirname, "..", file), "utf8");
    const create = read("app/api/vm/route.ts");
    expect(create).toContain("const selected = resolveCreateImage(provider, body, memoryMb, user.id);");
    expect(create).toContain("resolveVmImage(provider, body.image, process.env, { kind: body.kind, memoryMb, callerUserId });");
    expect(read("app/api/vm/base/routeShared.ts")).toMatch(/resolveVmImage\(provider, parsed\.body\.image, process\.env, \{[^}]*callerUserId: user\.id,[^}]*\}\)/);
  });

  test("the allowlist matches whole ids only", () => {
    expect(vmRestrictedImageAllowed("user-leo", allow("user-leo2,xuser-leo"))).toBe(false);
    expect(vmRestrictedImageAllowed("user-leo", allow(" user-leo "))).toBe(true);
    expect(vmRestrictedImageAllowed("", allow(","))).toBe(false);
    expect(vmRestrictedImageAllowed(undefined, allow("user-leo"))).toBe(false);
  });

  test("never a default, even for an allowlisted caller", () => {
    expect(listVmImageKindDefaults("freestyle", "desktop").some((entry) => entry.imageId === RESTRICTED_ID)).toBe(false);
    expect(findVmImageKindDefault("freestyle", "desktop")?.imageId).not.toBe(RESTRICTED_ID);
    expect(resolveVmImage("freestyle", undefined, allow("user-leo"), { callerUserId: "user-leo" }).image).not.toBe(RESTRICTED_ID);
  });

  test("the manifest check refuses a restricted default and a twin that disagrees", () => {
    const manifest = { schemaVersion: 1, images: [...realManifest.images, { ...restrictedEntry, defaultForKind: true }] };
    expect(imageManifestProblems(manifest as Parameters<typeof imageManifestProblems>[0])).toContain(
      "freestyle-cmux-devbox-restricted-test: a restricted test image cannot be a default",
    );
    expect(imageManifestProblems({ schemaVersion: 1, images: [...realManifest.images, restrictedEntry, unrestrictedTwin] } as Parameters<typeof imageManifestProblems>[0])).toContain(
      `${RESTRICTED_ID}: every entry for one image must agree on restricted`,
    );
  });
});
