import { expect, it } from "vitest";
import { ADMIT_TTL_MS, admitAgentSlot, bindAgentCreation, forgetAgentVm, HELD_TTL_MS, settleAgentSlot } from "../../src/limits/agent-slots.ts";
import { memoryLedgerStorage } from "../../src/limits/ledger.ts";

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
