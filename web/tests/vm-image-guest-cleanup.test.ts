import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { createVm, deleteLiveVms, deleteVm, Ledger, trackLiveVm, type Vm } from "../scripts/cmux-vm-image/guest";

const fakeVm = (deleted: string[], id: string) => ({ delete: async () => void deleted.push(id) }) as unknown as Vm;

describe("image harness VMs are deleted on a signal (no leak when a local timeout kills the run)", () => {
  test("deleteLiveVms deletes every tracked VM that was not deleted yet, by id, and records it in its ledger", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-cleanup-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const deleted: string[] = [];
    for (const id of ["vm-a", "vm-b"]) {
      ledger.record(id, "vm", `cmuxnp-dev-vmimg-t-${id}`);
      trackLiveVm({ vm: fakeVm(deleted, id), vmId: id, name: `cmuxnp-dev-vmimg-t-${id}`, ledger });
    }
    await deleteVm(fakeVm(deleted, "vm-a"), "vm-a", "cmuxnp-dev-vmimg-t-vm-a", ledger);
    expect(await deleteLiveVms()).toEqual(["vm-b"]);
    expect(deleted).toEqual(["vm-a", "vm-b"]);
    expect(ledger.live()).toEqual([]);
    expect(readFileSync(ledger.file, "utf8")).toContain("vm-b\tvm\tcmuxnp-dev-vmimg-t-vm-b");
    expect(await deleteLiveVms()).toEqual([]);
  });
});

describe("image harness VMs pause on their own when a run is lost (Lawrence, 2026-10-07)", () => {
  test("createVm asks Freestyle to pause the VM after at most 300 s of network idleness", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-idle-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    let options: Record<string, unknown> | undefined;
    const deleted: string[] = [];
    const fs = {
      vms: {
        create: async (opts: Record<string, unknown>) => {
          options = opts;
          return { vm: fakeVm(deleted, "vm-idle"), vmId: "vm-idle" };
        },
      },
    } as unknown as Parameters<typeof createVm>[0];
    await createVm(fs, ledger, { name: "cmuxnp-dev-vmimg-t-idle", snapshotId: "sh-test" });
    expect(typeof options?.idleTimeoutSeconds).toBe("number");
    expect(options?.idleTimeoutSeconds as number).toBeGreaterThan(0);
    expect(options?.idleTimeoutSeconds as number).toBeLessThanOrEqual(300);
    expect(await deleteLiveVms()).toEqual(["vm-idle"]);
  });
});
