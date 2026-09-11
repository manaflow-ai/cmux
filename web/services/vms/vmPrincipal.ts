// The machine principal: a cmux Cloud VM calling the control plane as itself.
//
// Nothing new is minted for this. Every request a guest makes to its alias host
// (`https://coderouter.cmux.internal`, or the reflection alias) is terminated by the
// provider's TLS edge and re-originated to this deployment with the machine's
// VM-bound coderouter route token and `x-cmux-vm-id` (services/coderouter/
// vmModelPlane.ts). `authenticateRequestRouteToken` already turns those headers into
// `{teamId, stackUserId, vmId}` and rejects a forged or mismatched VM id. This module
// adds the second half of "who is calling": the token's VM must be a live `cloud_vms`
// row that the token's user or team owns.
//
// Deny by default. A VM principal is accepted ONLY by the guest-facing reflection
// routes (app/api/vm/reflection); no other `/api/vm/*` route reads it, and no user
// (Stack) session is ever accepted on the guest-facing routes. The authority a
// machine gets is therefore read-only knowledge about itself and its siblings.
import { and, eq } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { authenticateRequestRouteToken, type RouteTokenIdentity } from "../coderouter/routeTokenAuth";
import { normalizeVmId } from "../coderouter/teamMachines";
import {
  VM_PRINCIPAL_LIVE_STATUSES,
  type VmPrincipal,
  type VmPrincipalLiveStatus,
  type VmPrincipalResult,
  type VmPrincipalRow,
} from "./vmPrincipalContract";

export {
  VM_PRINCIPAL_LIVE_STATUSES,
  vmPrincipalFailureResponse,
  vmPrincipalFailureStatus,
  type VmPrincipal,
  type VmPrincipalFailure,
  type VmPrincipalLiveStatus,
  type VmPrincipalResult,
  type VmPrincipalRow,
} from "./vmPrincipalContract";

type Authenticate = (
  token: string,
) => Promise<{ teamId: string; stackUserId: string; vmId?: string | null } | null>;

export type VmPrincipalDependencies = {
  /** Route-token lookup; the production default is the coderouter repository. */
  readonly authenticate?: Authenticate;
  /** `cloud_vms` by id (any status); the route decides what "live" means. */
  readonly loadVm: (vmId: string) => Promise<VmPrincipalRow | null>;
};

export async function loadCloudVmRow(vmId: string): Promise<VmPrincipalRow | null> {
  const id = normalizeVmId(vmId);
  if (!id) return null;
  const [row] = await cloudDb()
    .select({
      id: cloudVms.id,
      userId: cloudVms.userId,
      billingTeamId: cloudVms.billingTeamId,
      billingPlanId: cloudVms.billingPlanId,
      provider: cloudVms.provider,
      providerVmId: cloudVms.providerVmId,
      displayName: cloudVms.displayName,
      slug: cloudVms.slug,
      imageId: cloudVms.imageId,
      imageVersion: cloudVms.imageVersion,
      status: cloudVms.status,
      createdAt: cloudVms.createdAt,
      providerMetadata: cloudVms.providerMetadata,
    })
    .from(cloudVms)
    .where(and(eq(cloudVms.id, id)))
    .limit(1);
  return row ?? null;
}

const defaultDependencies: VmPrincipalDependencies = { loadVm: loadCloudVmRow };

export function isVmPrincipalLiveStatus(status: string): status is VmPrincipalLiveStatus {
  return (VM_PRINCIPAL_LIVE_STATUSES as readonly string[]).includes(status);
}

/**
 * Whether `identity` (the token's owner) may speak for `row`: the row was created
 * by that user, or belongs to the billing team the token was issued for. The same
 * ownership rule `teamMachines.ts` applies to per-machine usage.
 */
export function vmPrincipalOwns(row: VmPrincipalRow, identity: Pick<RouteTokenIdentity, "stackUserId" | "teamId">): boolean {
  if (row.userId === identity.stackUserId) return true;
  return row.billingTeamId !== null && row.billingTeamId === identity.teamId;
}

export async function requireVmPrincipal(
  request: Request,
  dependencies: VmPrincipalDependencies = defaultDependencies,
): Promise<VmPrincipalResult> {
  const auth = dependencies.authenticate
    ? await authenticateRequestRouteToken(request, dependencies.authenticate)
    : await authenticateRequestRouteToken(request);
  if (!auth.ok) return { ok: false, reason: auth.reason };
  const identity = auth.identity;
  if (identity.vmId === null) return { ok: false, reason: "vm_bound_token_required" };
  const row = await dependencies.loadVm(identity.vmId);
  if (!row) return { ok: false, reason: "vm_not_found" };
  if (!vmPrincipalOwns(row, identity)) return { ok: false, reason: "vm_owner_mismatch" };
  if (!isVmPrincipalLiveStatus(row.status)) return { ok: false, reason: "vm_not_live" };
  return { ok: true, principal: { vm: row, userId: identity.stackUserId, teamId: identity.teamId } };
}
