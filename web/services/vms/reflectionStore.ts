// Database loaders behind the reflection route: the owner's machines and the
// owner's identity snapshot. Kept apart from services/vms/reflection.ts so the
// payload builders stay pure.
import { and, eq, inArray, isNull, or } from "drizzle-orm";
import { cloudDb } from "../../db/client";
import { cloudVms } from "../../db/schema";
import { readIdentitySnapshot } from "../auth/identitySnapshot";
import type { ReflectionOwner } from "./reflection";
import { VM_PRINCIPAL_LIVE_STATUSES, type VmPrincipal, type VmPrincipalRow } from "./vmPrincipalContract";

const MAX_SIBLINGS = 1_000;

/**
 * Display facts only, so a stale snapshot is fine here: reflection never grants
 * anything from it, and the Stack access check already happened when the
 * snapshot was written. A year keeps a rarely-seen owner's email available
 * without ever asking Stack from the guest-facing path.
 */
const OWNER_SNAPSHOT_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1_000;

/** Every live machine the same owner has (the caller included). */
export async function listOwnerLiveVms(self: VmPrincipalRow): Promise<VmPrincipalRow[]> {
  const ownerScope = self.billingTeamId
    ? eq(cloudVms.billingTeamId, self.billingTeamId)
    : and(isNull(cloudVms.billingTeamId), eq(cloudVms.userId, self.userId));
  const rows = await cloudDb()
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
    .where(and(
      or(ownerScope, eq(cloudVms.id, self.id)),
      inArray(cloudVms.status, [...VM_PRINCIPAL_LIVE_STATUSES]),
    ))
    .limit(MAX_SIBLINGS);
  return rows;
}

/** The owner as reflection shows it; email and name come from the identity snapshot when one exists. */
export async function loadReflectionOwner(principal: VmPrincipal): Promise<ReflectionOwner> {
  const snapshot = await readIdentitySnapshot(principal.userId, OWNER_SNAPSHOT_MAX_AGE_MS);
  const user = snapshot?.user ?? null;
  return {
    userId: principal.userId,
    email: user?.primaryEmail ?? null,
    displayName: user?.displayName ?? null,
    teamId: principal.teamId,
    planId: principal.vm.billingPlanId ?? user?.billingPlanId ?? user?.userBillingPlanId ?? null,
  };
}
