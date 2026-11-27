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

describe("image VM delete retries a provider 5xx (run 44112930938: a passing smoke failed on its cleanup's 503)", () => {
  const providerError = (status: number) => Object.assign(new Error(`FreestyleApiError: ${status}`), { status });

  test("a 503 on delete is retried and the VM is deleted", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-5xx-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-delete-503";
    const name = "cmuxnp-dev-vmimg-t-503";
    let attempts = 0;
    const waits: number[] = [];
    const vm = {
      delete: async () => {
        attempts++;
        if (attempts === 1) throw providerError(503);
      },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });

    await deleteVm(vm, id, name, ledger, { sleep: async (ms) => void waits.push(ms) });
    expect(attempts).toBe(2);
    expect(waits.length).toBe(1);
    expect(ledger.live()).toEqual([]);
    expect(await deleteLiveVms()).toEqual([]);
  });

  test("a 5xx that never clears still fails after the bounded retries, and the VM stays tracked", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-5xx-out-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-delete-500";
    const name = "cmuxnp-dev-vmimg-t-500";
    let attempts = 0;
    let down = true;
    const vm = {
      delete: async () => {
        attempts++;
        if (down) throw providerError(500);
      },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });

    await expect(deleteVm(vm, id, name, ledger, { sleep: async () => {}, delaysMs: [1, 1] })).rejects.toThrow("500");
    expect(attempts).toBe(3);
    expect(ledger.live()).toEqual([{ id, kind: "vm", name }]);
    down = false;
    expect(await deleteLiveVms()).toEqual([id]);
  });
});

describe("image VM delete retries a delete the client timed out (run 45829777164: smoke failed in vm.delete)", () => {
  const timeout = () => Object.assign(new Error("The operation timed out."), { name: "TimeoutError" });

  test("a TimeoutError on delete is retried and the VM is deleted", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-timeout-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-delete-timeout";
    const name = "cmuxnp-dev-vmimg-t-timeout";
    let attempts = 0;
    const vm = {
      delete: async () => {
        attempts++;
        if (attempts === 1) throw timeout();
      },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });

    await deleteVm(vm, id, name, ledger, { sleep: async () => {} });
    expect(attempts).toBe(2);
    expect(ledger.live()).toEqual([]);
    expect(await deleteLiveVms()).toEqual([]);
  });

  test("a delete that times out every try still fails after the bounded retries, and the VM stays tracked", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-timeout-out-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-delete-timeout-out";
    const name = "cmuxnp-dev-vmimg-t-timeout-out";
    let attempts = 0;
    let down = true;
    const vm = {
      delete: async () => {
        attempts++;
        if (down) throw timeout();
      },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });

    await expect(deleteVm(vm, id, name, ledger, { sleep: async () => {}, delaysMs: [1, 1] })).rejects.toThrow("timed out");
    expect(attempts).toBe(3);
    expect(ledger.live()).toEqual([{ id, kind: "vm", name }]);
    down = false;
    expect(await deleteLiveVms()).toEqual([id]);
  });
});

describe("image VM cleanup when provider deletion fails", () => {
  test("keeps a failed VM tracked and the second exact-id delete succeeds", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-retry-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-delete-retry";
    const name = "cmuxnp-dev-vmimg-t-retry";
    let attempts = 0;
    const vm = {
      delete: async () => {
        attempts++;
        if (attempts === 1) throw new Error("temporary provider refusal");
      },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });

    await expect(deleteVm(vm, id, name, ledger)).rejects.toThrow("temporary provider refusal");
    expect(ledger.live()).toEqual([{ id, kind: "vm", name }]);
    expect(readFileSync(ledger.file, "utf8")).toContain("delete-failed");
    expect(await deleteLiveVms()).toEqual([id]);
    expect(attempts).toBe(2);
    expect(ledger.live()).toEqual([]);
  });

  test("failed signal cleanup retries, names the still-live VM and completes others", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-fault-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    let fail = true;
    let attempts = 0;
    let successful = 0;
    const failing = {
      delete: async () => {
        attempts++;
        if (fail) throw new Error("provider outage");
      },
    } as unknown as Vm;
    const passing = {
      delete: async () => { successful++; },
    } as unknown as Vm;
    for (const [vm, id] of [[failing, "vm-stuck"], [passing, "vm-other"]] as const) {
      const name = `cmuxnp-dev-vmimg-t-${id}`;
      ledger.record(id, "vm", name);
      trackLiveVm({ vm, vmId: id, name, ledger });
    }
    try {
      await expect(deleteLiveVms()).rejects.toThrow("vm-stuck");
      expect(attempts).toBe(2);
      expect(successful).toBe(1);
      expect(ledger.live().map((row) => row.id)).toEqual(["vm-stuck"]);
    } finally {
      fail = false;
      expect(await deleteLiveVms()).toEqual(["vm-stuck"]);
    }
    expect(ledger.live()).toEqual([]);
  });

  test("a provider 404 is a confirmed already-gone image VM", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-guest-delete-gone-"));
    const ledger = new Ledger(path.join(dir, "resources.tsv"));
    const id = "vm-already-gone";
    const name = "cmuxnp-dev-vmimg-t-gone";
    const vm = {
      delete: async () => { throw Object.assign(new Error("gone"), { status: 404 }); },
    } as unknown as Vm;
    ledger.record(id, "vm", name);
    trackLiveVm({ vm, vmId: id, name, ledger });
    await deleteVm(vm, id, name, ledger);
    expect(ledger.live()).toEqual([]);
    expect(await deleteLiveVms()).toEqual([]);
  });
});
