import type { cloudDb } from "../../db/client";
import {
  withAccountDeletionUserMutation,
  type AccountDeletionUserMutationLease,
} from "../account/deletionLock";

/**
 * Lease key for a Stack team's metadata. Every read-modify-write of a team's
 * `clientReadOnlyMetadata` or `serverMetadata` (admin Team grants, admin VM
 * deals, the Stripe Team subscription sync, the legacy coderouter vault) runs
 * under this key in the account-mutation lease table, so one writer cannot
 * store a stale copy over another's change.
 */
export function teamMutationKey(teamId: string): string {
  return `team:${teamId}`;
}

/**
 * Runs one team metadata write under the team lease. The operation must load
 * the team inside the callback; a copy read before the lease may be stale.
 * A busy lease throws `AccountDeletionUserMutationInProgressError`, which the
 * Stripe webhook treats as retryable.
 */
export async function withTeamMetadataMutation<Result>(
  db: ReturnType<typeof cloudDb>,
  teamId: string,
  operation: (lease: AccountDeletionUserMutationLease) => Promise<Result>,
): Promise<Result> {
  return await withAccountDeletionUserMutation(db, teamMutationKey(teamId), operation);
}
