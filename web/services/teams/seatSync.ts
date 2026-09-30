import { after } from "next/server";
import { reconcileTeamSeats } from "../billing/teamSeats";
import { databaseTeamSeatQueue, type TeamSeatQueue } from "../billing/teamSeatQueue";

/**
 * The membership fact that drives Team seat billing. The Stack membership
 * write has already succeeded when this runs, so it only records the fact
 * and never throws into the caller: billing follows membership, membership
 * never waits on billing. Tests pass a recording fake.
 */
export type TeamSeatSync = {
  membershipChanged(stackTeamId: string): Promise<void>;
};

export type SeatSyncDependencies = {
  readonly queue?: TeamSeatQueue;
  readonly reconcile?: (stackTeamId: string) => Promise<unknown>;
  /** Runs `task` after the response; the default is Next `after()`. */
  readonly defer?: (task: () => Promise<unknown>) => void;
};

export async function noteTeamMembershipChanged(
  stackTeamId: string,
  dependencies: SeatSyncDependencies = {},
): Promise<void> {
  const queue = dependencies.queue ?? databaseTeamSeatQueue;
  try {
    await queue.markDirty(stackTeamId);
  } catch (error) {
    // The cron pass cannot see an unrecorded change, so make the loss visible.
    console.error("team seat dirty mark failed", {
      stackTeamId,
      errorType: error instanceof Error ? error.name : typeof error,
    });
    return;
  }
  const reconcile = dependencies.reconcile ?? ((teamId: string) => reconcileTeamSeats({ teamIds: [teamId] }));
  (dependencies.defer ?? deferAfterResponse)(() =>
    reconcile(stackTeamId).catch((error: unknown) => {
      console.error("inline team seat reconcile failed", {
        stackTeamId,
        errorType: error instanceof Error ? error.name : typeof error,
      });
    }),
  );
}

function deferAfterResponse(task: () => Promise<unknown>): void {
  try {
    after(task);
  } catch {
    // No Next request scope (scripts, tests): run it now, never throw.
    void task().catch(() => undefined);
  }
}

export const defaultTeamSeatSync: TeamSeatSync = {
  membershipChanged: (stackTeamId) => noteTeamMembershipChanged(stackTeamId),
};
