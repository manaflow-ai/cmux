import { describe, expect, test } from "bun:test";

import {
  THROWAWAY_VM_IDLE_TIMEOUT_SECONDS,
  builderVmsForRun,
  ciRunTag,
  ciVmTags,
  deleteAll,
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

describe("a promotion run's builder", () => {
  test("only the builder named for this run's slug is selected", () => {
    const vms: TaggedVm[] = [
      { id: "mine", displayName: "cmux-devbox-builder cmux-devbox-123-1" },
      { id: "attempt-10", displayName: "cmux-devbox-builder cmux-devbox-123-10" },
      { id: "local-bake", displayName: "cmux-devbox-builder devbox-20261028-120000" },
      { id: "customer", displayName: "my box" },
      { id: "unnamed" },
    ];
    expect(builderVmsForRun(vms, "cmux-devbox-123-1").map((vm) => vm.id)).toEqual(["mine"]);
    expect(() => builderVmsForRun(vms, "devbox-20261028-120000")).toThrow();
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
  ];

  test("selects what the run made and no manifest names", () => {
    const doomed = runSnapshotSelection(rows, slug, new Set(["sh-promoted"]));
    expect(doomed.map((row) => row.id).sort()).toEqual(["sh-bake", "sh-bake-unslugged", "sh-lg", "sh-unslugged"]);
  });

  test("refuses a slug that is not a run's", () => {
    expect(() => runSnapshotSelection(rows, "cmux-devbox", new Set())).toThrow();
    expect(() => runSnapshotSelection(rows, "cmux-devbox-123", new Set())).toThrow();
    expect(() => runSnapshotSelection(rows, "cmux-devbox-ci-1-1", new Set())).toThrow();
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
