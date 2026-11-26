import { describe, expect, test } from "bun:test";
import {
  planFreestyleCustomerBackfill,
  summarizeBackfill,
  type BackfillOwnerRow,
} from "../scripts/cloud-vm/freestyleCustomerBackfill";

const ALICE = "8f3c1e2a-4b5d-4e6f-8a7b-9c0d1e2f3a4b";
const BOB = "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d";

function row(providerVmId: string, userId: string, overrides: Partial<BackfillOwnerRow> = {}): BackfillOwnerRow {
  return { cloudVmId: `row-${providerVmId}-${userId.slice(0, 4)}`, providerVmId, userId, status: "running", ...overrides };
}

describe("Freestyle customer backfill plan", () => {
  test("tags an untagged machine with its row's owner, paused machines included", () => {
    const plan = planFreestyleCustomerBackfill(
      [{ id: "vm-a", state: "paused", metadata: { cmux: "cloud" } }],
      [row("vm-a", ALICE)],
    );
    expect(plan).toEqual([{
      kind: "tag", vmId: "vm-a", state: "paused", from: null, to: ALICE, cloudVmIds: [`row-vm-a-${ALICE.slice(0, 4)}`], rowStatuses: ["running"],
    }]);
  });

  test("is idempotent: a machine already carrying its owner plans nothing", () => {
    const plan = planFreestyleCustomerBackfill([{ id: "vm-a", state: "running", customerId: ALICE }], [row("vm-a", ALICE)]);
    expect(plan).toEqual([{ kind: "tagged", vmId: "vm-a" }]);
  });

  test("the database wins over a different customer already on the machine", () => {
    const [action] = planFreestyleCustomerBackfill([{ id: "vm-a", state: "running", customerId: BOB }], [row("vm-a", ALICE)]);
    expect(action).toMatchObject({ kind: "tag", from: BOB, to: ALICE });
  });

  test("never guesses an owner for a machine no row names", () => {
    const plan = planFreestyleCustomerBackfill([{ id: "vm-dev", state: "running", metadata: { cmux: "cloud" } }, { id: "vm-bench", state: "stopped" }], []);
    expect(plan).toEqual([
      { kind: "unowned", vmId: "vm-dev", state: "running", cmux: "cloud" },
      { kind: "unowned", vmId: "vm-bench", state: "stopped", cmux: null },
    ]);
  });

  test("rows that agree on one owner tag once; rows that disagree tag nothing", () => {
    const agreeing = planFreestyleCustomerBackfill(
      [{ id: "vm-a", state: "running" }],
      [row("vm-a", ALICE, { status: "failed" }), row("vm-a", ALICE, { cloudVmId: "row-2" })],
    );
    expect(agreeing[0]).toMatchObject({ kind: "tag", to: ALICE, rowStatuses: ["failed", "running"] });
    const disagreeing = planFreestyleCustomerBackfill([{ id: "vm-a", state: "running" }], [row("vm-a", BOB), row("vm-a", ALICE)]);
    expect(disagreeing).toEqual([{ kind: "conflict", vmId: "vm-a", userIds: [BOB, ALICE].sort() }]);
  });

  test("an owner id Freestyle would refuse is reported, not sent", () => {
    const plan = planFreestyleCustomerBackfill([{ id: "vm-a", state: "running" }], [row("vm-a", "not a valid id")]);
    expect(plan).toEqual([{ kind: "invalid", vmId: "vm-a", userId: "not a valid id" }]);
  });

  test("a deleted account's shared-team machine loses that account's id and never gets the sentinel", () => {
    const deletedRow = row("vm-a", "deleted-account");
    const stale = planFreestyleCustomerBackfill([{ id: "vm-a", state: "paused", customerId: ALICE }], [deletedRow]);
    expect(stale).toEqual([{ kind: "detach", vmId: "vm-a", state: "paused", from: ALICE, cloudVmIds: [deletedRow.cloudVmId] }]);
    const clear = planFreestyleCustomerBackfill([{ id: "vm-a", state: "paused" }], [deletedRow]);
    expect(clear).toEqual([{ kind: "tagged", vmId: "vm-a" }]);
  });

  test("summary counts every kind", () => {
    const plan = planFreestyleCustomerBackfill(
      [{ id: "vm-a", state: "running" }, { id: "vm-b", state: "running", customerId: ALICE }, { id: "vm-c", state: "running" }],
      [row("vm-a", ALICE), row("vm-b", ALICE)],
    );
    expect(summarizeBackfill(plan)).toEqual({ tag: 1, detach: 0, tagged: 1, unowned: 1, conflict: 0, invalid: 0 });
  });
});
