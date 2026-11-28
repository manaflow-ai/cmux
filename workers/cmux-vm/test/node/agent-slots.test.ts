import { expect, it } from "vitest";
import { ADMIT_TTL_MS, admitAgentSlot, bindAgentCreation, forgetAgentVm, HELD_TTL_MS, settleAgentSlot } from "../../src/limits/agent-slots.ts";
import { creationNeverSent, memoryLedgerStorage } from "../../src/limits/ledger.ts";

const agent = "key:ak_1";

it("admits creates in flight atomically under the key's budget", async () => {
  const storage = memoryLedgerStorage();
  // Two VMs live, budget three: one create fits, the one racing it does not.
  expect(await admitAgentSlot(storage, agent, 3, ["vm_a", "vm_b"], 0, "s1")).toBe(true);
  expect(await admitAgentSlot(storage, agent, 3, ["vm_a", "vm_b"], 0, "s2")).toBe(false);
  // Another key's budget is its own.
  expect(await admitAgentSlot(storage, "key:ak_2", 3, ["vm_c", "vm_d"], 0, "s3")).toBe(true);
});

it("counts a recorded VM that a listing read before it landed does not show, and counts it once when it does", async () => {
  const storage = memoryLedgerStorage();
  expect(await admitAgentSlot(storage, agent, 2, ["vm_a"], 0, "s1")).toBe(true);
  await settleAgentSlot(storage, agent, "s1", { recorded: "vm_new" }, 10);
  // A stale listing (vm_new's row not yet read) still counts vm_new: 1 + 1 reaches the budget.
  expect(await admitAgentSlot(storage, agent, 2, ["vm_a"], 20, "s2")).toBe(false);
  // A fresh listing has it: still two, not three.
  expect(await admitAgentSlot(storage, agent, 3, ["vm_a", "vm_new"], 20, "s3")).toBe(true);
});

it("frees the budget when the VM is deleted, and when a failed create gives its slot back", async () => {
  const storage = memoryLedgerStorage();
  expect(await admitAgentSlot(storage, agent, 1, [], 0, "s1")).toBe(true);
  await settleAgentSlot(storage, agent, "s1", { recorded: "vm_x" }, 1);
  await forgetAgentVm(storage, "vm_x", "ck_1");
  expect(await admitAgentSlot(storage, agent, 1, [], 2, "s2")).toBe(true);
  await settleAgentSlot(storage, agent, "s2", "released", 3);
  expect(await admitAgentSlot(storage, agent, 1, [], 4, "s3")).toBe(true);
});

it("holds the slot of a create that may exist upstream unrecorded until a retry records it or it is deleted", async () => {
  const storage = memoryLedgerStorage();
  expect(await admitAgentSlot(storage, agent, 1, [], 0, "s1")).toBe(true);
  await settleAgentSlot(storage, agent, "s1", { held: "ck_1", vmId: "vm_x" }, 1);
  // Past an in-flight slot's lifetime the held one still counts.
  expect(await admitAgentSlot(storage, agent, 1, [], ADMIT_TTL_MS + 10, "s2")).toBe(false);
  // Its pending row, once listed, is the same VM.
  expect(await admitAgentSlot(storage, agent, 2, ["vm_x"], ADMIT_TTL_MS + 10, "s3")).toBe(true);
  await settleAgentSlot(storage, agent, "s3", "released", ADMIT_TTL_MS + 11);
  await bindAgentCreation(storage, agent, "ck_1", "vm_x", ADMIT_TTL_MS + 12);
  await forgetAgentVm(storage, "vm_x", "ck_1");
  expect(await admitAgentSlot(storage, agent, 1, [], ADMIT_TTL_MS + 13, "s4")).toBe(true);
  // A held slot left alone lapses after HELD_TTL_MS.
  await settleAgentSlot(storage, agent, "s4", { held: "ck_2", vmId: "vm_y" }, 0);
  expect(await admitAgentSlot(storage, agent, 1, [], HELD_TTL_MS + 1, "s5")).toBe(true);
});

it("drops a held slot whose creation provably sent nothing, and keeps one whose send began or has no receipt", async () => {
  const storage = memoryLedgerStorage();
  const progress = (dispatch: unknown) => ({ phase: "creating", vmId: "vm_00000000000000000000000001", reservationId: "slot", context: "provider", createdBy: "key:owner", ...(dispatch === undefined ? {} : { dispatch }) });
  const record = (dispatch: unknown) => ({ fingerprint: "f", leaseUntilMs: 0, expiresMs: HELD_TTL_MS * 2, progress: progress(dispatch) });
  // Slots held before the settle fix: a queue-refused create (dispatch ready) held as if it might exist.
  for (const [ck, dispatch] of [["ck_ready", { state: "ready", token: "t" }], ["ck_rejected", { state: "rejected", token: "t" }], ["ck_sent", { state: "sent", token: "t", at: 0 }], ["ck_legacy", undefined]] as const) {
    await storage.put(`idem:${ck}`, record(dispatch));
    await storage.put(`agentslot:${agent}:${ck}`, { expiresMs: HELD_TTL_MS, creationKey: ck, vmId: `vm_${ck}` });
  }
  expect(await creationNeverSent(storage, "ck_ready")).toBe(true);
  expect(await creationNeverSent(storage, "ck_rejected")).toBe(true);
  expect(await creationNeverSent(storage, "ck_sent")).toBe(false);
  expect(await creationNeverSent(storage, "ck_legacy")).toBe(false);
  expect(await creationNeverSent(storage, "ck_missing")).toBe(false);
  // Budget 3: the sent and legacy slots still count (2), the never-sent two are dropped, so one create fits.
  expect(await admitAgentSlot(storage, agent, 3, [], 1, "s1", creationNeverSent)).toBe(true);
  expect(await admitAgentSlot(storage, agent, 3, [], 1, "s2", creationNeverSent)).toBe(false);
  expect(await storage.get(`agentslot:${agent}:ck_ready`)).toBeUndefined();
  expect(await storage.get(`agentslot:${agent}:ck_sent`)).toBeDefined();
});
