import { describe, expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { FreestyleApiError } from "freestyle";
import { CREATE_ATTEMPT_KEY, CREATE_SERVER_ERROR_RETRY_DELAYS_MS, createVmRetrying, deleteLiveVms, Ledger, type Vm } from "../scripts/cmux-vm-image/guest";

// Image roll 44172829602 (job 134409902686, 2026-11-17): the agents layer was snapshotted, then the app layer's
// builder create from it answered HTTP 500 "Internal server error" once, and the whole roll failed with
// "BAKE FAILED: FreestyleApiError: Internal server error". The ledger shows the create returned no VM.
const serverError = () => new FreestyleApiError(500, { code: "INTERNAL_SERVER_ERROR", message: "Internal server error" }, "/v5/vms");
const fakeVm = (deleted: string[], id: string) => ({ delete: async () => void deleted.push(id) }) as unknown as Vm;

type Listed = { id: string; displayName?: string | null; metadata: Record<string, string> };

/**
 * A fake provider: `script` answers each create; `ghosts[n]` are VMs the provider shows once create n (from 1) has
 * failed, as a 5xx that answered while the provider still booted the VM. `others` are other runs' VMs it always lists.
 */
function harness(script: Array<"500" | "400" | "ok">, ghosts: Record<number, Listed[]> = {}, others: Listed[] = []) {
  const ledger = new Ledger(path.join(mkdtempSync(path.join(os.tmpdir(), "cmux-create-5xx-")), "resources.tsv"));
  const deleted: string[] = [];
  const waits: number[] = [];
  const lines: string[] = [];
  const sent: Array<Record<string, unknown>> = [];
  const queries: string[] = [];
  let shown: Listed[] = [...others];
  let creates = 0;
  const fs = {
    vms: {
      create: async (options: Record<string, unknown>) => {
        sent.push(options);
        const next = script.shift();
        creates++;
        if (next !== "ok") shown = [...shown, ...(ghosts[creates] ?? [])];
        if (next === "500") throw serverError();
        if (next === "400") throw new FreestyleApiError(400, { code: "BAD_REQUEST", message: "snapshot not found" }, "/v5/vms");
        return { vm: fakeVm(deleted, `vm-${creates}`), vmId: `vm-${creates}` };
      },
      // The provider's metadata filter: an exact key:value match.
      list: async (options: { metadata?: string }) => {
        queries.push(options.metadata ?? "");
        const [key, value] = (options.metadata ?? "").split(":");
        return { vms: shown.filter((vm) => vm.metadata[key!] === value && !deleted.includes(vm.id)), totalCount: 0 };
      },
      delete: async (id: string) => void deleted.push(id),
    },
  } as unknown as Parameters<typeof createVmRetrying>[0];
  const deps = { sleep: async (ms: number) => void waits.push(ms), log: (line: string) => void lines.push(line), attemptPrefix: "run" };
  return { fs, ledger, deleted, waits, lines, sent, queries, deps, creates: () => creates };
}

const NAME = "cmuxnp-dev-vmimg-agt-4134b2210d691fb5";

describe("an image builder create the provider answers with a server error", () => {
  test("is sent again after a wait, and the bake goes on with the VM the next create made", async () => {
    const h = harness(["500", "ok"]);
    const created = await createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps);
    expect(created.vmId).toBe("vm-2");
    expect(h.waits).toEqual([CREATE_SERVER_ERROR_RETRY_DELAYS_MS[0]]);
    expect(h.lines[0]).toContain(`PROVIDER ERROR: create ${NAME} from sh-agents answered 500`);
    expect(h.sent.map((o) => (o.metadata as Record<string, string>)[CREATE_ATTEMPT_KEY])).toEqual(["run-0", "run-1"]);
    expect(await deleteLiveVms()).toEqual(["vm-2"]);
  });

  test("the VM a failed create made anyway is found by its attempt tag after the wait, recorded and deleted; another run's builder of the same layer slug is left alone", async () => {
    const h = harness(["500", "ok"], { 1: [{ id: "vm-ghost", displayName: NAME, metadata: { [CREATE_ATTEMPT_KEY]: "run-0" } }] }, [
      { id: "vm-other-run", displayName: NAME, metadata: { [CREATE_ATTEMPT_KEY]: "other-0" } },
      { id: "vm-untagged", displayName: NAME, metadata: {} },
    ]);
    await createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps);
    expect(h.queries).toEqual([`${CREATE_ATTEMPT_KEY}:run-0`]);
    expect(h.deleted).toEqual(["vm-ghost"]);
    expect(h.ledger.live().map((r) => r.id)).toEqual(["vm-2"]);
    expect(await deleteLiveVms()).toEqual(["vm-2"]);
  });

  test("after the last server error the last attempt's VM is deleted too, then the error goes to the caller", async () => {
    const last = CREATE_SERVER_ERROR_RETRY_DELAYS_MS.length + 1;
    const h = harness(Array.from({ length: last }, () => "500" as const), { [last]: [{ id: "vm-last-ghost", metadata: { [CREATE_ATTEMPT_KEY]: `run-${last - 1}` } }] });
    await expect(createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps)).rejects.toThrow("Internal server error");
    expect(h.deleted).toEqual(["vm-last-ghost"]);
    expect(h.ledger.live()).toEqual([]);
  });

  test("a failed lookup is logged and the retry still runs", async () => {
    const h = harness(["500", "ok"]);
    (h.fs.vms as unknown as { list: () => Promise<never> }).list = async () => {
      throw new Error("list refused");
    };
    const created = await createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps);
    expect(created.vmId).toBe("vm-2");
    expect(h.lines.some((l) => l.includes("could not check") && l.includes("list refused"))).toBe(true);
    expect(await deleteLiveVms()).toEqual(["vm-2"]);
  });

  test("past the budget the last server error goes to the caller", async () => {
    const h = harness(Array.from({ length: CREATE_SERVER_ERROR_RETRY_DELAYS_MS.length + 1 }, () => "500" as const));
    await expect(createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps)).rejects.toThrow("Internal server error");
    expect(h.creates()).toBe(CREATE_SERVER_ERROR_RETRY_DELAYS_MS.length + 1);
    expect(h.waits).toEqual([...CREATE_SERVER_ERROR_RETRY_DELAYS_MS]);
  });

  test("a refusal (4xx) is never retried", async () => {
    const h = harness(["400", "ok"]);
    await expect(createVmRetrying(h.fs, h.ledger, { name: NAME, snapshotId: "sh-agents" }, h.deps)).rejects.toThrow("snapshot not found");
    expect(h.creates()).toBe(1);
    expect(h.waits).toEqual([]);
  });

  test("the budget stays a couple of minutes, so a real outage still fails the bake", () => {
    const total = CREATE_SERVER_ERROR_RETRY_DELAYS_MS.reduce((a, b) => a + b, 0);
    expect(total).toBeGreaterThanOrEqual(30_000);
    expect(total).toBeLessThanOrEqual(180_000);
  });
});
