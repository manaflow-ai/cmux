// Read-only ownership lookups over `cloud_vms` for per-machine CodeRouter
// usage. A machine belongs to a billing team when `billing_team_id` matches,
// or, for personal organizations (whose team id is the Stack user id), when
// the row has no billing team and was created by that user. Destroyed rows
// stay visible so usage a machine spent before deletion remains attributable.
import { and, desc, eq, isNull, or } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";

const MAX_TEAM_MACHINES = 1_000;
const VM_UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

export type TeamMachine = {
  readonly vmId: string;
  /** The provider's machine id, the `id` that `GET /api/vm` lists. */
  readonly providerVmId: string | null;
  readonly displayName: string | null;
  readonly destroyed: boolean;
  readonly createdAt: string;
};

/** Lowercased canonical `cloud_vms.id`, or null when the input is not a UUID. */
export function normalizeVmId(value: string | null | undefined): string | null {
  const candidate = value?.trim().toLowerCase() ?? "";
  return VM_UUID_PATTERN.test(candidate) ? candidate : null;
}

function teamScope(teamId: string) {
  return or(
    eq(cloudVms.billingTeamId, teamId),
    and(isNull(cloudVms.billingTeamId), eq(cloudVms.userId, teamId)),
  );
}

function machineFromRow(row: {
  id: string;
  providerVmId: string | null;
  displayName: string | null;
  status: string;
  createdAt: Date;
}): TeamMachine {
  const displayName = row.displayName?.trim() ?? "";
  return {
    vmId: row.id,
    providerVmId: row.providerVmId?.trim() || null,
    displayName: displayName ? displayName : null,
    destroyed: row.status === "destroyed",
    createdAt: row.createdAt.toISOString(),
  };
}

export async function findTeamMachine(
  teamId: string,
  vmId: string,
): Promise<TeamMachine | null> {
  const id = normalizeVmId(vmId);
  if (!id) return null;
  const [row] = await cloudDb()
    .select({
      id: cloudVms.id,
      providerVmId: cloudVms.providerVmId,
      displayName: cloudVms.displayName,
      status: cloudVms.status,
      createdAt: cloudVms.createdAt,
    })
    .from(cloudVms)
    .where(and(eq(cloudVms.id, id), teamScope(teamId)))
    .limit(1);
  return row ? machineFromRow(row) : null;
}

export async function listTeamMachines(
  teamId: string,
): Promise<readonly TeamMachine[]> {
  const rows = await cloudDb()
    .select({
      id: cloudVms.id,
      providerVmId: cloudVms.providerVmId,
      displayName: cloudVms.displayName,
      status: cloudVms.status,
      createdAt: cloudVms.createdAt,
    })
    .from(cloudVms)
    .where(teamScope(teamId))
    .orderBy(desc(cloudVms.createdAt))
    .limit(MAX_TEAM_MACHINES);
  return rows.map(machineFromRow);
}
