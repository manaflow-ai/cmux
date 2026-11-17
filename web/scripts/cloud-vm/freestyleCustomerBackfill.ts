import { DELETED_ACCOUNT_ACTOR_ID } from "../../services/auth/deletedAccount";
import { freestyleCustomerId } from "../../services/vms/drivers/freestyleCustomer";

/** One Freestyle machine as `vms.list` reports it. */
export type BackfillVm = {
  readonly id: string;
  readonly state: string;
  readonly customerId?: string;
  readonly metadata?: Readonly<Record<string, string>>;
};

/** One `cloud_vms` row that names a Freestyle machine. */
export type BackfillOwnerRow = {
  readonly cloudVmId: string;
  readonly providerVmId: string;
  readonly userId: string;
  readonly status: string;
};

export type BackfillAction =
  /** Send `customer: { customerId: to }`; `from` is what Freestyle has now. */
  | { readonly kind: "tag"; readonly vmId: string; readonly state: string; readonly from: string | null; readonly to: string; readonly cloudVmIds: readonly string[]; readonly rowStatuses: readonly string[] }
  /** A deleted account's machine its shared team kept still names that account: send `customerId: null`. */
  | { readonly kind: "detach"; readonly vmId: string; readonly state: string; readonly from: string; readonly cloudVmIds: readonly string[] }
  /** Already carries its owner (or, for a deleted account's machine, no customer): nothing to send. */
  | { readonly kind: "tagged"; readonly vmId: string }
  /** No row in this database names it: another environment's, a benchmark's, or a leak. Never guessed. */
  | { readonly kind: "unowned"; readonly vmId: string; readonly state: string; readonly cmux: string | null }
  /** Rows of different users name it; the database has to be fixed first. */
  | { readonly kind: "conflict"; readonly vmId: string; readonly userIds: readonly string[] }
  /** The owner's id is outside Freestyle's customer id alphabet. */
  | { readonly kind: "invalid"; readonly vmId: string; readonly userId: string };

/**
 * What the backfill would send for each machine. The database is the source
 * of truth for ownership: a machine is tagged only when every row that names
 * it agrees on one owner, and a machine tagged with someone else is retagged.
 * A machine whose owner is the deleted-account sentinel names no account, so
 * any customer it still carries is cleared.
 * Running it again after an apply plans nothing for the machines it tagged.
 */
export function planFreestyleCustomerBackfill(
  vms: readonly BackfillVm[],
  rows: readonly BackfillOwnerRow[],
): BackfillAction[] {
  const rowsByVm = new Map<string, BackfillOwnerRow[]>();
  for (const row of rows) {
    const list = rowsByVm.get(row.providerVmId) ?? [];
    list.push(row);
    rowsByVm.set(row.providerVmId, list);
  }
  return vms.map((vm): BackfillAction => {
    const owners = rowsByVm.get(vm.id);
    if (!owners) return { kind: "unowned", vmId: vm.id, state: vm.state, cmux: vm.metadata?.cmux ?? null };
    const userIds = [...new Set(owners.map((row) => row.userId))].sort();
    if (userIds.length > 1) return { kind: "conflict", vmId: vm.id, userIds };
    if (userIds[0] === DELETED_ACCOUNT_ACTOR_ID) {
      return vm.customerId
        ? { kind: "detach", vmId: vm.id, state: vm.state, from: vm.customerId, cloudVmIds: owners.map((row) => row.cloudVmId) }
        : { kind: "tagged", vmId: vm.id };
    }
    const customerId = freestyleCustomerId({ customerId: userIds[0]! });
    if (!customerId) return { kind: "invalid", vmId: vm.id, userId: userIds[0]! };
    if (vm.customerId === customerId) return { kind: "tagged", vmId: vm.id };
    return {
      kind: "tag",
      vmId: vm.id,
      state: vm.state,
      from: vm.customerId ?? null,
      to: customerId,
      cloudVmIds: owners.map((row) => row.cloudVmId),
      rowStatuses: [...new Set(owners.map((row) => row.status))].sort(),
    };
  });
}

/** Counts per action kind, for the run summary. */
export function summarizeBackfill(actions: readonly BackfillAction[]): Record<BackfillAction["kind"], number> {
  const summary = { tag: 0, detach: 0, tagged: 0, unowned: 0, conflict: 0, invalid: 0 };
  for (const action of actions) summary[action.kind] += 1;
  return summary;
}
