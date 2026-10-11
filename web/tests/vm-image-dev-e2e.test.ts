import { describe, expect, test } from "bun:test";
import { assertDevOrigin, readEnvFile, bootedSnapshotProblem, readDevChannel } from "../scripts/cmux-vm-image/dev-e2e";

describe("dev end-to-end script guards", () => {
  test("refuses every origin except the development API", () => {
    expect(() => assertDevOrigin("https://cmux-api-development.debussy.workers.dev")).not.toThrow();
    for (const origin of ["https://cloud-api.cmux.dev", "https://cloud-api-staging.cmux.dev", "http://cmux-api-development.debussy.workers.dev", "https://evil.example"]) {
      expect(() => assertDevOrigin(origin)).toThrow(/development only/);
    }
  });
  test("reads KEY=value files without exposing other lines", () => {
    expect(readEnvFile('# c\nexport A="x y"\nB=z\nnot a line\n')).toEqual({ A: "x y", B: "z" });
  });
});

describe("the e2e machine booted the dev channel's snapshot (provider VM record, read only)", () => {
  const channel = { snapshot: "cmuxnp-dev-vmimg-auto8-db3743e", snapshot_id: "sh-2edc51e3a9cb417d89ed7e7159effb0b" };

  test("passes when the VM's snapshotId equals channels/dev.json", () => {
    expect(bootedSnapshotProblem({ snapshotId: channel.snapshot_id, sourceSnapshotSlugAtCreate: channel.snapshot }, channel)).toBeNull();
  });

  test("fails on another snapshot, on a missing id, and on a slug that names another image", () => {
    expect(bootedSnapshotProblem({ snapshotId: "sh-42ecf781e5a1460b991c7bff18ae4caf", sourceSnapshotSlugAtCreate: "cmuxnp-dev-vmimg-auto7-5c5cf35" }, channel)).toBe(
      "booted sh-42ecf781e5a1460b991c7bff18ae4caf (cmuxnp-dev-vmimg-auto7-5c5cf35), channels/dev.json names sh-2edc51e3a9cb417d89ed7e7159effb0b (cmuxnp-dev-vmimg-auto8-db3743e)",
    );
    expect(bootedSnapshotProblem({ snapshotId: null }, channel)).toBe("the provider VM record has no snapshotId");
    expect(bootedSnapshotProblem({ snapshotId: channel.snapshot_id, sourceSnapshotSlugAtCreate: "cmuxnp-dev-vmimg-auto7-5c5cf35" }, channel)).toContain("slug at create cmuxnp-dev-vmimg-auto7-5c5cf35");
  });

  test("the checked-in channel file is what the step reads", () => {
    const dev = readDevChannel();
    expect(dev.snapshot_id).toMatch(/^sh-[0-9a-f]{32}$/);
    expect(dev.snapshot).toMatch(/^cmuxnp-dev-vmimg-/);
  });
});
