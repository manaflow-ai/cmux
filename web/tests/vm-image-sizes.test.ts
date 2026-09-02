import { describe, expect, test } from "bun:test";
import {
  VM_IMAGE_SIZES,
  VM_IMAGE_SIZE_NAMES,
  pickVmImageSizeForMemory,
  vmImageSize,
  vmImageSizeRank,
} from "../services/vms/images/sizes";
import {
  imageManifestProblems,
  promoteImageManifestEntry,
  type DevboxImageManifest,
  type DevboxManifestEntry,
} from "../scripts/devbox-image-common";

// Machine sizes are Freestyle's t-shirt ladder (freestyle-vms
// catalog/snapshots.json), one cmux snapshot per size, picked by the plan's
// memory. These pin the ladder and the per-size promotion semantics.

const entry = (overrides: Partial<DevboxManifestEntry> = {}): DevboxManifestEntry => ({
  provider: "freestyle",
  version: "freestyle-cmux-devbox-test",
  imageId: "sh-master",
  envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
  cmuxdRemoteCommit: "none-cmux-tui",
  builtAt: "2026-09-02T00:00:00.000Z",
  builderScriptVersion: "deadbeef",
  agentToolResolvedVersions: {},
  validationStatus: "passed",
  notes: "epoch test",
  ...overrides,
});

describe("size ladder", () => {
  test("mirrors Freestyle's catalog exactly, smallest first", () => {
    expect(VM_IMAGE_SIZE_NAMES).toEqual(["sm", "md", "lg", "xl", "2xl"]);
    expect(VM_IMAGE_SIZES.map((s) => [s.name, s.cpu, s.memoryMb, s.storageMb, s.freestyleBase])).toEqual([
      ["sm", 2, 4096, 16384, "freestyle/ubuntu-sm"],
      ["md", 4, 8192, 32768, "freestyle/ubuntu"],
      ["lg", 8, 16384, 65536, "freestyle/ubuntu-lg"],
      ["xl", 16, 32768, 131072, "freestyle/ubuntu-xl"],
      ["2xl", 32, 65536, 131072, "freestyle/ubuntu-2xl"],
    ]);
    // Grow-only resize means the ladder must be monotonic in every dimension
    // except disk between xl and 2xl, which Freestyle keeps equal.
    for (let i = 1; i < VM_IMAGE_SIZES.length; i += 1) {
      expect(VM_IMAGE_SIZES[i].cpu).toBeGreaterThan(VM_IMAGE_SIZES[i - 1].cpu);
      expect(VM_IMAGE_SIZES[i].memoryMb).toBeGreaterThan(VM_IMAGE_SIZES[i - 1].memoryMb);
      expect(VM_IMAGE_SIZES[i].storageMb).toBeGreaterThanOrEqual(VM_IMAGE_SIZES[i - 1].storageMb);
    }
    expect(vmImageSizeRank("lg")).toBe(2);
    expect(vmImageSize("xl").memoryMb).toBe(32768);
  });

  test("the plan's memory picks the smallest size that fits", () => {
    // cmux's plan knobs are memory-only; vCPU and disk follow the row.
    expect(pickVmImageSizeForMemory(512)?.name).toBe("sm");
    expect(pickVmImageSizeForMemory(4096)?.name).toBe("sm");
    expect(pickVmImageSizeForMemory(4097)?.name).toBe("md");
    // cmux's paid default (24 GiB) is between lg and xl: it gets xl.
    expect(pickVmImageSizeForMemory(24576)?.name).toBe("xl");
    expect(pickVmImageSizeForMemory(32768)?.name).toBe("xl");
    expect(pickVmImageSizeForMemory(65536)?.name).toBe("2xl");
    expect(pickVmImageSizeForMemory(65537)).toBeNull();
  });
});

describe("promoteImageManifestEntry with sizes", () => {
  const sizes = [
    { imageId: "sh-lg", size: { ...vmImageSize("lg") } },
    { imageId: "sh-sm", size: { ...vmImageSize("sm") } },
    { imageId: "sh-xl", size: { ...vmImageSize("xl") } },
  ];
  const base: DevboxImageManifest = {
    schemaVersion: 1,
    images: [
      // A pre-ladder, size-less default: the sized promotion replaces it.
      entry({ version: "freestyle-old", imageId: "sh-old", kind: "base", defaultForKind: true }),
      // An old desktop default: not this promotion's kind, untouched.
      entry({ version: "freestyle-old-desktop", imageId: "sh-old-d", kind: "desktop", defaultForKind: true }),
    ],
  };

  test("writes one entry per kind and size, ladder order, and demotes the size-less default", () => {
    const next = promoteImageManifestEntry(base, entry(), { kinds: ["base"], sizes, validationNotes: "ok" });
    expect(imageManifestProblems(next)).toEqual([]);
    expect(next.images[0]).toMatchObject({ version: "freestyle-old", defaultForKind: false });
    expect(next.images[1]).toMatchObject({ version: "freestyle-old-desktop", defaultForKind: true });
    expect(next.images.slice(2).map((e) => [e.version, e.imageId, e.kind, e.size?.name, e.defaultForKind])).toEqual([
      ["freestyle-cmux-devbox-test-sm", "sh-sm", "base", "sm", true],
      ["freestyle-cmux-devbox-test-lg", "sh-lg", "base", "lg", true],
      ["freestyle-cmux-devbox-test-xl", "sh-xl", "base", "xl", true],
    ]);
    expect(next.images[2].size).toEqual({ name: "sm", cpu: 2, memoryMb: 4096, storageMb: 16384, freestyleBase: "freestyle/ubuntu-sm" });
    expect(next.images[2].notes).toBe("epoch test ok");
  });

  test("two kinds times three sizes is six entries, desktop versions suffixed", () => {
    const next = promoteImageManifestEntry(base, entry(), { kinds: ["desktop", "base"], sizes });
    expect(imageManifestProblems(next)).toEqual([]);
    expect(next.images.slice(2).map((e) => e.version)).toEqual([
      "freestyle-cmux-devbox-test-sm",
      "freestyle-cmux-devbox-test-lg",
      "freestyle-cmux-devbox-test-xl",
      "freestyle-cmux-devbox-test-sm-base",
      "freestyle-cmux-devbox-test-lg-base",
      "freestyle-cmux-devbox-test-xl-base",
    ]);
    expect(next.images[1]).toMatchObject({ version: "freestyle-old-desktop", defaultForKind: false });
  });

  test("a second sized promotion demotes only the same kind+size rows", () => {
    const first = promoteImageManifestEntry(base, entry(), { kinds: ["base"], sizes });
    const next = promoteImageManifestEntry(
      first,
      entry({ version: "freestyle-cmux-devbox-next", imageId: "sh-master-2" }),
      { kinds: ["base"], sizes: [{ imageId: "sh-lg-2", size: { ...vmImageSize("lg") } }] },
    );
    expect(imageManifestProblems(next)).toEqual([]);
    const defaults = next.images.filter((e) => e.defaultForKind && (e.kind ?? "base") === "base").map((e) => [e.size?.name, e.imageId]);
    expect(defaults).toEqual([["sm", "sh-sm"], ["xl", "sh-xl"], ["lg", "sh-lg-2"]]);
  });

  test("refuses to list the same image twice for a kind+size", () => {
    const first = promoteImageManifestEntry(base, entry(), { kinds: ["base"], sizes });
    expect(() => promoteImageManifestEntry(first, entry(), { kinds: ["base"], sizes })).toThrow(/already listed .* \(base, sm\)/);
  });
});

describe("imageManifestProblems with sizes", () => {
  test("flags mixed sized and size-less defaults, off-ladder sizes, and duplicate size defaults", () => {
    const bad: DevboxImageManifest = {
      schemaVersion: 1,
      images: [
        entry({ version: "a", imageId: "sh-a", kind: "base", defaultForKind: true }),
        entry({ version: "b", imageId: "sh-b", kind: "base", defaultForKind: true, size: { ...vmImageSize("lg") } }),
        entry({ version: "c", imageId: "sh-c", kind: "base", defaultForKind: true, size: { ...vmImageSize("lg") } }),
        entry({ version: "d", imageId: "sh-d", kind: "base", size: { name: "huge" as never, cpu: 1, memoryMb: 1, storageMb: 1 } }),
      ],
    };
    const problems = imageManifestProblems(bad);
    for (const expected of [
      "freestyle/base: defaults mix sized and size-less entries",
      "freestyle/base/lg: 2 entries flagged defaultForKind",
      "d: size huge is not on the ladder",
    ]) {
      expect(problems.some((problem) => problem.includes(expected))).toBe(true);
    }
  });
});
