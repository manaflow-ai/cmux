import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { FreestyleApiError } from "freestyle";
import { CREATE_SERVER_ERROR_RETRY_DELAYS_MS, createVmRetrying, deleteLiveVms, Ledger, type Vm } from "../scripts/cmux-vm-image/guest";

// Image roll 44172829602 (job 134409902686, 2026-11-17): the agents layer was snapshotted, then the app layer's
// builder create from it answered HTTP 500 "Internal server error" once, and the whole roll failed with
// "BAKE FAILED: FreestyleApiError: Internal server error". The ledger shows the create returned no VM.
const serverError = () => new FreestyleApiError(500, { code: "INTERNAL_SERVER_ERROR", message: "Internal server error" }, "/v5/vms");
const fakeVm = (deleted: string[], id: string) => ({ delete: async () => void deleted.push(id) }) as unknown as Vm;

function harness(script: Array<"500" | "400" | "ok">, listed: Array<{ id: string; displayName?: string | null }> = []) {
  const ledger = new Ledger(path.join(mkdtempSync(path.join(os.tmpdir(), "cmux-create-5xx-")), "resources.tsv"));
  const deleted: string[] = [];
  const waits: number[] = [];
  const lines: string[] = [];
  let creates = 0;
  const fs = {
    vms: {
      create: async () => {
        const next = script.shift();
        creates++;
        if (next === "500") throw serverError();
        if (next === "400") throw new FreestyleApiError(400, { code: "BAD_REQUEST", message: "snapshot not found" }, "/v5/vms");
        return { vm: fakeVm(deleted, `vm-${creates}`), vmId: `vm-${creates}` };
      },
      list: async () => ({ vms: listed.splice(0), totalCount: 0 }),
      delete: async (id: string) => void deleted.push(id),
    },
  } as unknown as Parameters<typeof createVmRetrying>[0];
  const deps = { sleep: async (ms: number) => void waits.push(ms), log: (line: string) => void lines.push(line) };
  return { fs, ledger, deleted, waits, lines, deps, creates: () => creates };
}

describe("an image builder create the provider answers with a server error", () => {
  test("is sent again after a wait, and the bake goes on with the VM the next create made", async () => {
    const h = harness(["500", "ok"]);
    const created = await createVmRetrying(h.fs, h.ledger, { name: "cmuxnp-dev-vmimg-ci-1-1", snapshotId: "sh-agents" }, h.deps);
    expect(created.vmId).toBe("vm-2");
    expect(h.waits).toEqual([CREATE_SERVER_ERROR_RETRY_DELAYS_MS[0]]);
    expect(h.lines[0]).toContain("PROVIDER ERROR: create cmuxnp-dev-vmimg-ci-1-1 from sh-agents answered 500");
    expect(await deleteLiveVms()).toEqual(["vm-2"]);
  });

  test("a VM the failed create made anyway (same name, not this run's) is deleted and recorded before the retry", async () => {
    const h = harness(["500", "ok"], [{ id: "vm-orphan", displayName: "cmuxnp-dev-vmimg-ci-1-1" }, { id: "vm-other", displayName: "someone-else" }]);
    await createVmRetrying(h.fs, h.ledger, { name: "cmuxnp-dev-vmimg-ci-1-1", snapshotId: "sh-agents" }, h.deps);
    expect(h.deleted).toEqual(["vm-orphan"]);
    expect(h.ledger.live().map((r) => r.id)).toEqual(["vm-2"]);
    expect(await deleteLiveVms()).toEqual(["vm-2"]);
  });

  test("past the budget the last server error goes to the caller", async () => {
    const h = harness(Array.from({ length: CREATE_SERVER_ERROR_RETRY_DELAYS_MS.length + 1 }, () => "500" as const));
    await expect(createVmRetrying(h.fs, h.ledger, { name: "cmuxnp-dev-vmimg-ci-1-1", snapshotId: "sh-agents" }, h.deps)).rejects.toThrow("Internal server error");
    expect(h.creates()).toBe(CREATE_SERVER_ERROR_RETRY_DELAYS_MS.length + 1);
    expect(h.waits).toEqual([...CREATE_SERVER_ERROR_RETRY_DELAYS_MS]);
  });

  test("a refusal (4xx) is never retried", async () => {
    const h = harness(["400", "ok"]);
    await expect(createVmRetrying(h.fs, h.ledger, { name: "cmuxnp-dev-vmimg-ci-1-1", snapshotId: "sh-agents" }, h.deps)).rejects.toThrow("snapshot not found");
    expect(h.creates()).toBe(1);
    expect(h.waits).toEqual([]);
  });

  test("the budget stays a couple of minutes, so a real outage still fails the bake", () => {
    const total = CREATE_SERVER_ERROR_RETRY_DELAYS_MS.reduce((a, b) => a + b, 0);
    expect(total).toBeGreaterThanOrEqual(30_000);
    expect(total).toBeLessThanOrEqual(180_000);
  });
});
