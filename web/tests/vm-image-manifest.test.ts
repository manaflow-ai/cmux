import { describe, expect, test } from "bun:test";
import path from "node:path";
import { spawnSync } from "node:child_process";
import {
  DEVBOX_SOURCE_SCHEMA,
  appendImageManifestEntries,
  bakeMetadata,
  bakeScriptPath,
  devboxDockerfileAtCommit,
  sha256File,
  upgradeDevboxSourceRecords,
  devboxImageEpoch,
  devboxImageLadderProblems,
  devboxUnifiedSnapshotProblems,
  devboxSourceDigest,
  devboxSourceDriftProblems,
  imageManifestProblems,
  manifestEntryEpoch,
  manifestEntrySkeleton,
  promoteImageManifestEntry,
  readDevboxDockerfile,
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
  agentToolResolvedVersions: { "@anthropic-ai/claude-code": "2.1.267" },
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

  test("has a complete, shape-correct base and desktop ladder", () => {
    expect(devboxImageLadderProblems(readImageManifest())).toEqual([]);
  });

  test("every default was baked from this checkout's devbox sources", () => {
    // The manifest is the only source of truth for the image users get, so
    // main must not describe a machine the promoted default is not: every
    // default carries the Dockerfile's CMUX_IMAGE_EPOCH and, once recorded,
    // the digest of the files and pins the bake took from this checkout. A
    // pin or template change lands together with its promotion, and a
    // rollback reverts the promotion commit whole (sources included).
    expect(devboxSourceDriftProblems(readImageManifest())).toEqual([]);
  });
});

describe("devboxSourceDriftProblems", () => {
  const dockerfile = readDevboxDockerfile();
  const epoch = devboxImageEpoch(dockerfile);
  const current = (layers: "desktop" | "base", overrides: Partial<DevboxManifestEntry> = {}): DevboxManifestEntry =>
    passedEntry({
      kind: layers,
      defaultForKind: true,
      epoch,
      devboxSource: { layers, digest: devboxSourceDigest(layers, dockerfile), schema: DEVBOX_SOURCE_SCHEMA },
      notes: `cmux devbox epoch ${epoch}`,
      ...overrides,
    });
  const manifestOf = (...images: DevboxManifestEntry[]): DevboxImageManifest => ({ schemaVersion: 1, images });

  test("accepts defaults at the current epoch and digest, and ignores non-defaults and other providers", () => {
    expect(devboxSourceDriftProblems(manifestOf(current("desktop"), current("base", { version: "b" })))).toEqual([]);
    expect(
      devboxSourceDriftProblems(
        manifestOf(
          current("desktop"),
          passedEntry({ version: "old", imageId: "sh-old", defaultForKind: false, epoch: "1999-01-01-r1" }),
          passedEntry({ version: "e2b", provider: "e2b" as unknown as DevboxManifestEntry["provider"], defaultForKind: true, epoch: "1999-01-01-r1" }),
        ),
      ),
    ).toEqual([]);
  });

  test("flags a default baked at another epoch, read from the field or from the notes", () => {
    const stale = devboxSourceDriftProblems(manifestOf(current("desktop", { epoch: "1999-01-01-r1" })));
    expect(stale).toHaveLength(1);
    expect(stale[0]).toContain("baked at devbox epoch 1999-01-01-r1");
    expect(stale[0]).toContain(`the Dockerfile is at ${epoch}`);
    // Older entries carry the epoch only in `notes`; a promoted ladder from before
    // an epoch bump is the exact case this catches.
    const legacy = passedEntry({ kind: "base", defaultForKind: true, notes: "cmux devbox epoch 1999-01-01-r1 Devbox on Freestyle." });
    expect(manifestEntryEpoch(legacy)).toBe("1999-01-01-r1");
    expect(devboxSourceDriftProblems(manifestOf(legacy))).toHaveLength(1);
    expect(devboxSourceDriftProblems(manifestOf(passedEntry({ kind: "base", defaultForKind: true, notes: `cmux devbox epoch ${epoch}` })))).toEqual([]);
    expect(manifestEntryEpoch(passedEntry({ notes: "no epoch here" }))).toBeUndefined();
  });

  test("flags a default whose recorded source digest is not this checkout's, per layer set", () => {
    const drifted = devboxSourceDriftProblems(manifestOf(current("desktop", { devboxSource: { layers: "desktop", digest: "0".repeat(64) } })));
    expect(drifted).toHaveLength(1);
    expect(drifted[0]).toContain("baked from devbox sources 000000000000");
    // A desktop image promoted as the base kind is held to the desktop sources it was baked from.
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "desktop", digest: devboxSourceDigest("desktop", dockerfile), schema: DEVBOX_SOURCE_SCHEMA } })))).toEqual([]);
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "desktop", digest: devboxSourceDigest("base", dockerfile), schema: DEVBOX_SOURCE_SCHEMA } })))).toHaveLength(1);
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "vnc" as "base", digest: "x" } })))[0]).toContain("is not desktop|base");
    // An entry keeps the formula it was recorded with: a schema-1 record (no
    // `schema` field, the first promoted ladders) is checked with schema 1 and
    // stays valid across a formula change; an unknown schema is refused.
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "base", digest: devboxSourceDigest("base", dockerfile, 1) } })))).toEqual([]);
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "base", digest: devboxSourceDigest("base", dockerfile, 1), schema: 2 } })))).toHaveLength(1);
    expect(devboxSourceDriftProblems(manifestOf(current("base", { devboxSource: { layers: "base", digest: "x", schema: 9 } })))[0]).toContain("is not a known formula");
    // A Dockerfile change is what makes the checkout drift from the default.
    const bumped = dockerfile.replace(/^ENV CMUX_IMAGE_EPOCH=.*$/m, "ENV CMUX_IMAGE_EPOCH=2099-01-01-r1");
    const problems = devboxSourceDriftProblems(manifestOf(current("desktop")), "freestyle", bumped);
    expect(problems.some((problem) => problem.includes("baked at devbox epoch"))).toBe(true);
    expect(problems.some((problem) => problem.includes("baked from devbox sources"))).toBe(true);
  });

  test("the bake records the epoch and the source digest, and promotion carries them onto every variant", () => {
    const metadata = bakeMetadata({ sha: "abc123", epoch }, path.join(import.meta.dirname, "../scripts/build-devbox-freestyle.ts"), "desktop");
    expect(metadata.devboxSource).toEqual({ layers: "desktop", digest: devboxSourceDigest("desktop", dockerfile), schema: DEVBOX_SOURCE_SCHEMA });
    const entry = manifestEntrySkeleton("freestyle", "freestyle-x", "sh-x", "FREESTYLE_SANDBOX_SNAPSHOT", metadata, "", "desktop");
    expect(entry).toMatchObject({ epoch, devboxSource: metadata.devboxSource, validationStatus: "unknown" });
    const promoted = promoteImageManifestEntry(manifestOf(), { ...entry, validationStatus: "passed" }, {
      kinds: ["desktop", "base"],
      sizes: [
        { imageId: "sh-x-sm", size: { name: "sm", cpu: 2, memoryMb: 4096, storageMb: 16384 } },
        { imageId: "sh-x-md", size: { name: "md", cpu: 4, memoryMb: 8192, storageMb: 32768 } },
      ],
    });
    expect(promoted.images).toHaveLength(4);
    for (const row of promoted.images) {
      expect(row).toMatchObject({ epoch, devboxSource: metadata.devboxSource, defaultForKind: true });
    }
    expect(devboxSourceDriftProblems(promoted)).toEqual([]);
  });
});

describe("devboxImageLadderProblems", () => {
  test("rejects splitting a shared snapshot or dropping its desktop layer", () => {
    const manifest = readImageManifest();
    const split = {
      ...manifest,
      images: manifest.images.map((entry) => entry.kind === "base" && entry.defaultForKind
        ? { ...entry, imageId: `${entry.imageId}-shell`, devboxSource: undefined }
        : entry),
    };
    expect(devboxUnifiedSnapshotProblems(manifest)).toEqual([]);
    const problems = devboxUnifiedSnapshotProblems(split);
    expect(problems.some((problem) => problem.includes("share one snapshot"))).toBe(true);
    expect(problems.some((problem) => problem.includes("include the desktop layer"))).toBe(true);
  });

  test("rejects a missing size and a wrong shape", () => {
    const manifest = readImageManifest();
    const base = manifest.images.filter((entry) => {
      const isBaseDefault =
        entry.provider === "freestyle" &&
        (entry.kind ?? "base") === "base" &&
        entry.defaultForKind;
      return !isBaseDefault || !["sm", "md"].includes(entry.size?.name ?? "");
    });
    const sm = manifest.images.find(
      (entry) => entry.provider === "freestyle" && (entry.kind ?? "base") === "base" && entry.size?.name === "sm" && entry.defaultForKind,
    )!;
    const bad = {
      ...manifest,
      images: [
        ...base,
        { ...sm, size: { ...sm.size!, memoryMb: sm.size!.memoryMb + 1 }, version: `${sm.version}-bad`, imageId: `${sm.imageId}-bad`, defaultForKind: true },
      ],
    };
    const problems = devboxImageLadderProblems(bad);
    expect(problems.some((problem) => problem.includes("missing default size md"))).toBe(true);
    expect(problems.some((problem) => problem.includes("shape is"))).toBe(true);
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

  test("adds a kind to an image promoted earlier without re-listing the rows it already has", () => {
    // One snapshot serving both kinds, promoted in two steps: the desktop
    // rows first, then `--kinds desktop,base` from the same bake. The desktop
    // rows are left as they are, the base rows are appended with the `-base`
    // suffix, and the provider's previous base defaults are demoted.
    const sizes = [
      { imageId: "sh-x-sm", size: { name: "sm" as const, cpu: 2, memoryMb: 4096, storageMb: 16384 } },
      { imageId: "sh-x-md", size: { name: "md" as const, cpu: 4, memoryMb: 8192, storageMb: 32768 } },
    ];
    const withDesktop = promoteImageManifestEntry(base, passedEntry({ version: "freestyle-x" }), { kinds: ["desktop"], sizes });
    const both = promoteImageManifestEntry(withDesktop, passedEntry({ version: "freestyle-x" }), { kinds: ["desktop", "base"], sizes });
    expect(imageManifestProblems(both)).toEqual([]);
    expect(both.images.slice(withDesktop.images.length).map((e) => [e.version, e.kind, e.imageId, e.defaultForLocalDev ?? false])).toEqual([
      ["freestyle-x-sm-base", "base", "sh-x-sm", true],
      ["freestyle-x-md-base", "base", "sh-x-md", false],
    ]);
    expect(both.images.filter((e) => e.provider === "freestyle" && e.defaultForKind).map((e) => [e.version, e.kind])).toEqual([
      ["freestyle-x-sm", "desktop"],
      ["freestyle-x-md", "desktop"],
      ["freestyle-x-sm-base", "base"],
      ["freestyle-x-md-base", "base"],
    ]);
    expect(both.images.find((e) => e.version === "freestyle-old-base")?.defaultForKind).toBe(false);
    // Nothing left to add: refused, not silently a no-op.
    expect(() => promoteImageManifestEntry(both, passedEntry({ version: "freestyle-x" }), { kinds: ["desktop", "base"], sizes })).toThrow(/already listed as freestyle-x-sm \(desktop, sm\)/);
  });
});

describe("upgradeDevboxSourceRecords (promote --upgrade-source-schema)", () => {
  const dockerfile = readDevboxDockerfile();
  const epoch = devboxImageEpoch(dockerfile);
  const bakeScriptSha = sha256File(bakeScriptPath);
  const recorded = (layers: "desktop" | "base", overrides: Partial<DevboxManifestEntry> = {}): DevboxManifestEntry =>
    passedEntry({
      version: `freestyle-${layers}-v1`,
      imageId: `sh-${layers}-v1`,
      kind: layers,
      defaultForKind: true,
      epoch,
      repoCommit: "bakecommit",
      builderScriptVersion: bakeScriptSha,
      devboxSource: { layers, digest: devboxSourceDigest(layers, dockerfile, 1) },
      ...overrides,
    });
  const manifestOf = (...images: DevboxManifestEntry[]): DevboxImageManifest => ({ schemaVersion: 1, images });
  // The Dockerfile as committed at the entry's repoCommit, in tests a stand-in for `git show`.
  const sameDockerfile = (commit: string) => (commit === "bakecommit" ? dockerfile : null);

  test("moves a schema-1 default up only when its digest, builderScriptVersion and baked Dockerfile prove the checkout", () => {
    const result = upgradeDevboxSourceRecords(manifestOf(recorded("desktop"), recorded("base")), { dockerfileAt: sameDockerfile });
    expect(result.upgraded).toEqual(["freestyle-desktop-v1", "freestyle-base-v1"]);
    expect(result.skipped).toEqual([]);
    for (const entry of result.manifest.images) {
      expect(entry.devboxSource).toEqual({ layers: entry.kind, digest: devboxSourceDigest(entry.kind!, dockerfile, DEVBOX_SOURCE_SCHEMA), schema: DEVBOX_SOURCE_SCHEMA });
    }
    expect(devboxSourceDriftProblems(result.manifest)).toEqual([]);
    // Idempotent: nothing left to upgrade.
    expect(upgradeDevboxSourceRecords(result.manifest, { dockerfileAt: sameDockerfile }).upgraded).toEqual([]);
    // A Dockerfile that differs only in comments at the bake commit is the same recipe.
    const commented = upgradeDevboxSourceRecords(manifestOf(recorded("base")), { dockerfileAt: () => `# a comment\n${dockerfile}\n# another\n` });
    expect(commented.upgraded).toEqual(["freestyle-base-v1"]);
  });

  test("leaves an entry alone when its provenance is not proven, and never touches non-defaults", () => {
    const stale = recorded("base", { version: "stale", builderScriptVersion: "0".repeat(64) });
    const drifted = recorded("base", { version: "drifted", devboxSource: { layers: "base", digest: "1".repeat(64) } });
    const demoted = recorded("base", { version: "demoted", defaultForKind: false });
    const legacy = passedEntry({ version: "legacy", kind: "base", defaultForKind: true, epoch });
    const noCommit = recorded("base", { version: "nocommit", repoCommit: undefined });
    const result = upgradeDevboxSourceRecords(manifestOf(stale, drifted, demoted, legacy, noCommit), { dockerfileAt: sameDockerfile });
    expect(result.upgraded).toEqual([]);
    expect(result.skipped.map((row) => [row.version, row.reason])).toEqual([
      ["stale", "builderScriptVersion does not match this checkout's bake script"],
      ["drifted", "schema 1 digest does not match this checkout"],
      ["nocommit", `Dockerfile at repoCommit (none) is not available here; rebake to record schema ${DEVBOX_SOURCE_SCHEMA}`],
    ]);
    expect(result.manifest.images.every((e) => (e.devboxSource?.schema ?? 1) === 1)).toBe(true);
    // A different bake script than the one the entry recorded is not proven either.
    const other = upgradeDevboxSourceRecords(manifestOf(recorded("base")), { bakeScript: () => "export {};\n", dockerfileAt: sameDockerfile });
    expect(other.upgraded).toEqual([]);
  });

  test("a Dockerfile-only instruction change since the bake commit is not proven: no upgrade, rebake", () => {
    // Regression: a schema-1 record carries no Dockerfile instruction hash,
    // so the checkout's instructions must equal those at repoCommit before
    // schema 2 may claim them; an unavailable commit is not proof either.
    const bakedDockerfile = dockerfile.replace(/^    bubblewrap \\$/m, "    bubblewrap \\\n    cowsay \\");
    expect(bakedDockerfile).not.toBe(dockerfile);
    const changed = upgradeDevboxSourceRecords(manifestOf(recorded("base")), { dockerfileAt: () => bakedDockerfile });
    expect(changed.upgraded).toEqual([]);
    expect(changed.skipped).toEqual([{ version: "freestyle-base-v1", reason: `Dockerfile instructions changed since repoCommit bakecommit; rebake to record schema ${DEVBOX_SOURCE_SCHEMA}` }]);
    const unavailable = upgradeDevboxSourceRecords(manifestOf(recorded("base")), { dockerfileAt: () => null });
    expect(unavailable.upgraded).toEqual([]);
    expect(unavailable.skipped[0]?.reason).toContain("is not available here");
    // The real reader: an unknown but well-formed object id is not available;
    // anything that is not a full 40-hex object id is refused before git runs
    // (a manifest entry may come from a branch this checkout did not author,
    // so `repoCommit` is an argument to git, never shell text).
    expect(upgradeDevboxSourceRecords(manifestOf(recorded("base", { repoCommit: "0000000000000000000000000000000000000000" }))).skipped[0]?.reason).toContain("is not available here");
    for (const hostile of ["HEAD", "main", "d3b2da01be", "$(touch /tmp/pwned)", "x; echo pwned", "0".repeat(39) + ":../../etc/passwd"]) {
      expect(devboxDockerfileAtCommit(hostile)).toBeNull();
      expect(upgradeDevboxSourceRecords(manifestOf(recorded("base", { repoCommit: hostile }))).upgraded).toEqual([]);
    }
    // A real full object id that carries the file resolves through git: HEAD
    // exists in every checkout, shallow ones included.
    const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: path.join(import.meta.dirname, "../.."), encoding: "utf8" }).stdout.trim();
    expect(head).toMatch(/^[0-9a-f]{40}$/);
    expect(devboxDockerfileAtCommit(head)).toContain("CMUX_IMAGE_EPOCH=");
  });
});

describe("appendImageManifestEntries (promote --replay)", () => {
  // Two promotions in flight append to the same manifest. Whichever merges
  // second replays the rows its promotion appended (the --out summary's
  // `entries`) onto the manifest as merged: the other ladder is demoted for
  // every kind+size the replayed rows take over, nothing is removed, and the
  // outcome is byte-identical to having promoted after the merge.
  const size = (name: "sm" | "md", memoryMb: number) => ({ name, cpu: 2, memoryMb, storageMb: 16384 });
  const ladder = (tag: string, kind: "desktop" | "base", epoch: string): DevboxManifestEntry[] =>
    (["sm", "md"] as const).map((name, index) =>
      passedEntry({
        version: `freestyle-${tag}-${kind}-${name}`,
        imageId: `sh-${tag}-${kind}-${name}`,
        kind,
        defaultForKind: true,
        size: size(name, index === 0 ? 4096 : 8192),
        epoch,
        notes: `cmux devbox epoch ${epoch}`,
        ...(kind === "base" && name === "sm" ? { defaultForLocalDev: true } : {}),
      }),
    );
  const main: DevboxImageManifest = { schemaVersion: 1, images: [...ladder("old", "desktop", "e1"), ...ladder("old", "base", "e1")] };

  test("replaying a promotion onto a manifest that gained another ladder demotes that ladder and appends", () => {
    const theirs = appendImageManifestEntries(main, ladder("theirs", "base", "e1"));
    const mine = ladder("mine", "base", "e2");
    const replayed = appendImageManifestEntries(theirs, mine);
    expect(imageManifestProblems(replayed)).toEqual([]);
    expect(replayed.images.map((e) => [e.version, e.defaultForKind, e.defaultForLocalDev ?? false])).toEqual([
      ["freestyle-old-desktop-sm", true, false],
      ["freestyle-old-desktop-md", true, false],
      ["freestyle-old-base-sm", false, false],
      ["freestyle-old-base-md", false, false],
      ["freestyle-theirs-base-sm", false, false],
      ["freestyle-theirs-base-md", false, false],
      ["freestyle-mine-base-sm", true, true],
      ["freestyle-mine-base-md", true, false],
    ]);
    // Same result as promoting in the other order, up to row order.
    const otherOrder = appendImageManifestEntries(appendImageManifestEntries(main, mine), ladder("theirs", "base", "e1"));
    expect(otherOrder.images.filter((e) => e.defaultForKind).map((e) => e.version)).toEqual(
      ["freestyle-old-desktop-sm", "freestyle-old-desktop-md", "freestyle-theirs-base-sm", "freestyle-theirs-base-md"],
    );
    // Pure: inputs untouched.
    expect(theirs.images.find((e) => e.version === "freestyle-theirs-base-sm")?.defaultForKind).toBe(true);
  });

  test("a sized ladder retires size-less defaults of its kind; a size-less row leaves sized defaults alone", () => {
    const sizeless = passedEntry({ version: "freestyle-flat", imageId: "sh-flat", kind: "desktop", defaultForKind: true });
    const withFlat: DevboxImageManifest = { schemaVersion: 1, images: [sizeless] };
    const sized = appendImageManifestEntries(withFlat, ladder("new", "desktop", "e1"));
    expect(sized.images[0].defaultForKind).toBe(false);
    const flatOnSized = appendImageManifestEntries(main, [passedEntry({ version: "freestyle-flat2", imageId: "sh-flat2", kind: "desktop", defaultForKind: true })]);
    expect(flatOnSized.images.filter((e) => e.kind === "desktop" && e.defaultForKind).map((e) => e.version)).toEqual([
      "freestyle-old-desktop-sm",
      "freestyle-old-desktop-md",
      "freestyle-flat2",
    ]);
  });

  test("refuses rows that are not promotable", () => {
    expect(() => appendImageManifestEntries(main, [])).toThrow(/no manifest rows/);
    expect(() => appendImageManifestEntries(main, [passedEntry({ version: "x", imageId: "sh-old-desktop-sm", kind: "desktop", size: size("sm", 4096) })])).toThrow(/already listed as freestyle-old-desktop-sm \(desktop, sm\)/);
    expect(() => appendImageManifestEntries(main, [passedEntry({ version: "y", imageId: "sh-y", kind: "base", defaultForKind: true, validationStatus: "unknown" })])).toThrow(/validationStatus is unknown, not passed/);
    expect(() => appendImageManifestEntries(main, [{ ...passedEntry(), version: "" }])).toThrow(/without provider, version and imageId/);
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
