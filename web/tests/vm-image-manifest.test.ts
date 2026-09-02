import { describe, expect, test } from "bun:test";
import {
  imageManifestProblems,
  promoteImageManifestEntry,
  readImageManifest,
  type DevboxImageManifest,
  type DevboxManifestEntry,
} from "../scripts/devbox-image-common";

// The checked-in image manifest (services/vms/images/manifest.json) is the
// source of truth for the image Cloud VM users get: the resolver serves the
// entry flagged defaultForKind when no env selector is set, also in deployed
// runtimes. These tests pin the invariants that make that safe, and the
// promote step (promote-devbox-image.ts) that is the only sanctioned writer.

const passedEntry = (overrides: Partial<DevboxManifestEntry> = {}): DevboxManifestEntry => ({
  provider: "freestyle",
  version: "freestyle-cmux-devbox-test",
  imageId: "sh-0000000000000000000000000000test",
  envVar: "FREESTYLE_SANDBOX_SNAPSHOT",
  defaultForLocalDev: false,
  cmuxdRemoteCommit: "none-cmux-tui",
  repoCommit: "abc123",
  builtAt: "2026-09-02T00:00:00.000Z",
  builderScriptVersion: "deadbeef",
  agentToolResolvedVersions: { "@anthropic-ai/claude-code": "2.1.252" },
  validationStatus: "passed",
  notes: "cmux devbox epoch test",
  ...overrides,
});

describe("checked-in image manifest", () => {
  test("holds its invariants", () => {
    expect(imageManifestProblems(readImageManifest())).toEqual([]);
  });

  test("every defaultForKind entry is a validated image", () => {
    for (const entry of readImageManifest().images) {
      if (entry.defaultForKind) {
        expect({ version: entry.version, validationStatus: entry.validationStatus })
          .toEqual({ version: entry.version, validationStatus: "passed" });
      }
    }
  });
});

describe("promoteImageManifestEntry", () => {
  const base: DevboxImageManifest = {
    schemaVersion: 1,
    images: [
      passedEntry({
        version: "freestyle-old-desktop",
        imageId: "sh-old",
        kind: "desktop",
        defaultForKind: true,
        defaultForLocalDev: true,
      }),
      passedEntry({ version: "freestyle-old-base", imageId: "sh-old", kind: "base", defaultForKind: true }),
      // A foreign provider's entry: the type only knows freestyle now, but the
      // promote step must still leave such rows alone.
      passedEntry({
        provider: "e2b" as unknown as DevboxManifestEntry["provider"],
        version: "e2b-x",
        imageId: "cmux-devbox:x",
        envVar: "E2B_CMUXD_WS_TEMPLATE",
        kind: "base",
        defaultForKind: true,
      }),
    ],
  };

  test("appends one entry per kind, flags them default, and demotes the provider's old defaults", () => {
    const next = promoteImageManifestEntry(base, passedEntry(), {
      kinds: ["desktop", "base"],
      validationNotes: "Validated in test.",
    });
    // Pure: the input is untouched.
    expect(base.images[0].defaultForKind).toBe(true);
    expect(imageManifestProblems(next)).toEqual([]);
    expect(next.images).toHaveLength(5);
    expect(next.images.slice(0, 3).map((e) => [e.version, e.defaultForKind])).toEqual([
      ["freestyle-old-desktop", false],
      ["freestyle-old-base", false],
      // Another provider's defaults are not this promotion's business.
      ["e2b-x", true],
    ]);
    expect(next.images.slice(3)).toMatchObject([
      { version: "freestyle-cmux-devbox-test", kind: "desktop", defaultForKind: true },
      { version: "freestyle-cmux-devbox-test-base", kind: "base", defaultForKind: true },
    ]);
    expect(next.images[3].notes).toBe("cmux devbox epoch test Validated in test.");
  });

  test("promoting one kind leaves the other kind's default alone", () => {
    const next = promoteImageManifestEntry(base, passedEntry(), { kinds: ["base"] });
    expect(next.images.map((e) => [e.version, e.kind, e.defaultForKind])).toEqual([
      ["freestyle-old-desktop", "desktop", true],
      ["freestyle-old-base", "base", false],
      ["e2b-x", "base", true],
      ["freestyle-cmux-devbox-test", "base", true],
    ]);
  });

  test("refuses anything the verifier has not passed", () => {
    for (const status of ["unknown", "failed"] as const) {
      expect(() =>
        promoteImageManifestEntry(base, passedEntry({ validationStatus: status }), { kinds: ["base"] }),
      ).toThrow(/validationStatus is (unknown|failed), not passed/);
    }
  });

  test("refuses to list the same image twice for a kind, and refuses no kinds", () => {
    expect(() =>
      promoteImageManifestEntry(base, passedEntry({ imageId: "sh-old" }), { kinds: ["desktop"] }),
    ).toThrow(/already listed as freestyle-old-desktop \(desktop\)/);
    expect(() => promoteImageManifestEntry(base, passedEntry(), { kinds: [] })).toThrow(/no kinds/);
  });
});

describe("imageManifestProblems", () => {
  test("flags two defaults for one provider+kind and an unvalidated default", () => {
    const bad: DevboxImageManifest = {
      schemaVersion: 1,
      images: [
        passedEntry({ version: "a", imageId: "sh-a", kind: "base", defaultForKind: true }),
        passedEntry({ version: "b", imageId: "sh-b", kind: "base", defaultForKind: true, validationStatus: "unknown" }),
        passedEntry({ version: "c", imageId: "sh-c", defaultForLocalDev: true }),
        passedEntry({ version: "d", imageId: "sh-d", defaultForLocalDev: true }),
        passedEntry({ version: "d", imageId: "sh-e" }),
      ],
    };
    const problems = imageManifestProblems(bad);
    for (const expected of [
      "b: defaultForKind but validationStatus is unknown",
      "freestyle/base: 2 entries flagged defaultForKind",
      "freestyle/d: version listed more than once",
    ]) {
      expect(problems.some((problem) => problem.includes(expected))).toBe(true);
    }
  });
});
