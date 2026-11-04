import { describe, expect, test } from "bun:test";

import {
  THROWAWAY_VM_IDLE_TIMEOUT_SECONDS,
  builderVmsForRun,
  ciRunTag,
  ciVmTags,
  cleanupOnSignal,
  deleteAll,
  ledgerSnapshotIds,
  manifestImageIds,
  parseSince,
  runSnapshotSelection,
  throwawayVmOptions,
  vmsTaggedForRun,
  type TaggedVm,
} from "../scripts/cloud-vm/ci-leftovers";

const env = (values: Record<string, string>): NodeJS.ProcessEnv => ({ ...values }) as unknown as NodeJS.ProcessEnv;
const ci = env({ GITHUB_RUN_ID: "40801969902", GITHUB_RUN_ATTEMPT: "2" });

describe("CI run tags", () => {
  test("a run and attempt make one tag; outside CI there is none", () => {
    expect(ciRunTag(ci)).toBe("gh-40801969902-2");
    expect(ciRunTag(env({ GITHUB_RUN_ID: "7" }))).toBe("gh-7-1");
    expect(ciRunTag(env({}))).toBeNull();
    expect(ciRunTag(env({ GITHUB_RUN_ID: "x;y" }))).toBeNull();
    expect(ciVmTags(env({}))).toEqual({});
  });

  test("a throwaway machine pauses when idle, has a deadline, and carries the tag", () => {
    const options = throwawayVmOptions(ci);
    expect(options.idleTimeoutSeconds).toBe(THROWAWAY_VM_IDLE_TIMEOUT_SECONDS);
    expect(options.idleTimeoutSeconds).toBeGreaterThan(5 * 60);
    expect(options.ttlSeconds).toBeGreaterThan(options.idleTimeoutSeconds);
    expect(options.metadata).toEqual({ cmux: "ci", run: "gh-40801969902-2" });
  });

  test("only this run's machines are selected, whatever the list returned", () => {
    const vms: TaggedVm[] = [
      { id: "mine", metadata: { cmux: "ci", run: "gh-1-1" } },
      { id: "other-attempt", metadata: { cmux: "ci", run: "gh-1-2" } },
      { id: "other-run", metadata: { cmux: "ci", run: "gh-11-1" } },
      { id: "customer", metadata: { cmux: "cloud", run: "gh-1-1" } },
      { id: "untagged", metadata: {} },
      { id: "no-metadata" },
    ];
    expect(vmsTaggedForRun(vms, "gh-1-1").map((vm) => vm.id)).toEqual(["mine"]);
  });
});

const since = new Date("2026-10-29T04:00:00Z");
const during = "2026-10-29T04:10:00Z";
const before = "2026-10-29T03:00:00Z";

describe("a promotion run's builder", () => {
  const base = "freestyle/ubuntu-sm";
  const builder = (id: string, overrides: Partial<TaggedVm> = {}): TaggedVm => ({
    id,
    displayName: "cmux-devbox-builder cmux-devbox-123-1",
    snapshotId: "sh-base",
    sourceSnapshotSlugAtCreate: base,
    createdAt: during,
    metadata: {},
    ...overrides,
  });

  test("only this run's builder is selected: its name, its base, this run's window, no cmux metadata", () => {
    const vms: TaggedVm[] = [
      builder("mine"),
      builder("mine-no-metadata", { metadata: null }),
      builder("attempt-10", { displayName: "cmux-devbox-builder cmux-devbox-123-10" }),
      builder("local-bake", { displayName: "cmux-devbox-builder devbox-20261028-120000" }),
      builder("customer-same-name", { metadata: { cmux: "cloud" } }),
      builder("other-base", { snapshotId: "sh-other", sourceSnapshotSlugAtCreate: "freestyle/ubuntu" }),
      builder("before-the-run", { createdAt: before }),
      builder("no-created-at", { createdAt: null }),
      { id: "unnamed" },
    ];
    expect(builderVmsForRun(vms, "cmux-devbox-123-1", base, since).map((vm) => vm.id)).toEqual(["mine", "mine-no-metadata"]);
    expect(builderVmsForRun(vms, "cmux-devbox-123-1", "sh-base", since).map((vm) => vm.id)).toEqual(["mine", "mine-no-metadata"]);
    expect(() => builderVmsForRun(vms, "devbox-20261028-120000", base, since)).toThrow();
  });
});

describe("a promotion run's snapshots", () => {
  const slug = "cmux-devbox-123-1";
  const rows = [
    { id: "sh-bake", slug },
    { id: "sh-lg", slug: `${slug}-lg` },
    { id: "sh-unslugged", slug: null, displayName: `cmux devbox ${slug}-xl (8 vCPU · 16384 MiB · 65536 MiB)` },
    { id: "sh-bake-unslugged", displayName: `cmux devbox ${slug} (epoch 9, abcdef0123)` },
    { id: "sh-promoted", slug: `${slug}-md` },
    { id: "sh-attempt-10", slug: "cmux-devbox-123-10" },
    { id: "sh-other-run", slug: "cmux-devbox-1234-1" },
    { id: "sh-rebake", slug: "cmux-devbox-ci-202610280000-abc-def" },
    { id: "sh-pointer", slug: "cmux-devbox" },
    { id: "sh-other-label", displayName: "cmux devbox cmux-devbox-123-10 (epoch 9, abcdef0123)" },
  ].map((row) => ({ createdAt: during, ...row }));

  test("selects the run's slugs and what its log took, never a manifest's image", () => {
    const doomed = runSnapshotSelection(rows, slug, new Set(["sh-promoted"]), since, new Set(["sh-unslugged", "sh-promoted"]));
    expect(doomed.map((row) => row.id).sort()).toEqual(["sh-bake", "sh-lg", "sh-unslugged"]);
  });

  test("a display name alone never proves ownership (customers set display names)", () => {
    const doomed = runSnapshotSelection(rows, slug, new Set(), since);
    expect(doomed.map((row) => row.id)).not.toContain("sh-bake-unslugged");
    expect(doomed.map((row) => row.id)).not.toContain("sh-unslugged");
  });

  test("a slug that only starts with the run's slug is not the run's", () => {
    const odd = [{ id: "sh-odd", slug: `${slug}-mine`, createdAt: during }, { id: "sh-size", slug: `${slug}-2xl`, createdAt: during }];
    expect(runSnapshotSelection(odd, slug, new Set(), since).map((row) => row.id)).toEqual(["sh-size"]);
  });

  test("a same-named snapshot from before the run, or of unknown age, is never selected", () => {
    const old = [{ id: "sh-old", slug, createdAt: before }, { id: "sh-unknown", slug: `${slug}-lg`, createdAt: null }];
    expect(runSnapshotSelection(old, slug, new Set(), since)).toEqual([]);
  });

  test("refuses a slug that is not a run's", () => {
    expect(() => runSnapshotSelection(rows, "cmux-devbox", new Set(), since)).toThrow();
    expect(() => runSnapshotSelection(rows, "cmux-devbox-123", new Set(), since)).toThrow();
    expect(() => runSnapshotSelection(rows, "cmux-devbox-ci-1-1", new Set(), since)).toThrow();
  });

  test("--since is required and allows for clock skew", () => {
    expect(() => parseSince(undefined)).toThrow();
    expect(() => parseSince("")).toThrow();
    expect(parseSince("2026-10-29T04:05:00Z").toISOString()).toBe("2026-10-29T04:00:00.000Z");
  });
});

describe("ledger and manifests", () => {
  const a = `sh-${"a".repeat(32)}`;
  const b = `sh-${"b".repeat(32)}`;
  test("the run's log names the snapshots it took; a cut-off line proves nothing", () => {
    const log = [
      `SNAPSHOT_RESULT {"snapshotId":"${a}","sourceVmId":"vm1"}`,
      `  SNAPSHOT_TAKEN ${b}`,
      `SNAPSHOT_RESULT {"snapshotId":"sh-${"c".repeat(32)}"`,
      `echo SNAPSHOT_TAKEN sh-${"d".repeat(32)}`,
      "SNAPSHOT_TAKEN sh-short",
    ].join("\n");
    expect([...ledgerSnapshotIds(log)].sort()).toEqual([a, b]);
  });

  test("a manifest cut off mid-write reads as unreadable, not as empty", () => {
    expect(manifestImageIds(JSON.stringify({ schemaVersion: 1, images: [{ imageId: a }, { imageId: b }] }))).toEqual(new Set([a, b]));
    expect(manifestImageIds('{"schemaVersion":1,"images":[{"imageId":"sh-')).toBeNull();
    expect(manifestImageIds("")).toBeNull();
    expect(manifestImageIds("{}")).toBeNull();
  });
});

describe("cleanupOnSignal", () => {
  test("installs one handler per signal and removes them", () => {
    const before = { int: process.listenerCount("SIGINT"), term: process.listenerCount("SIGTERM") };
    const stop = cleanupOnSignal(async () => {});
    expect(process.listenerCount("SIGINT")).toBe(before.int + 1);
    expect(process.listenerCount("SIGTERM")).toBe(before.term + 1);
    stop();
    expect(process.listenerCount("SIGINT")).toBe(before.int);
    expect(process.listenerCount("SIGTERM")).toBe(before.term);
  });
});

describe("deleteAll", () => {
  test("a 404 counts as deleted and one failure does not stop the rest", async () => {
    const seen: string[] = [];
    const outcome = await deleteAll(["a", "gone", "broken", "b"], async (id) => {
      seen.push(id);
      if (id === "gone") throw Object.assign(new Error("VM not found"), { status: 404 });
      if (id === "broken") throw Object.assign(new Error("internal"), { status: 500 });
    }, () => {});
    expect(seen).toEqual(["a", "gone", "broken", "b"]);
    expect(outcome).toEqual({ deleted: ["a", "gone", "b"], failed: ["broken"] });
  });
});
