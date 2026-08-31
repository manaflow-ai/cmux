import { and, eq, lte } from "drizzle-orm";

import { cloudDb } from "../../db/client";
import { cloudVms, cloudVmStateTransitions } from "../../db/schema";
export {
  aggregateActiveComputeHours,
  billingPeriodThrough,
  calculateActiveComputeHours,
  isActiveComputeState,
  ACTIVE_COMPUTE_STATES,
  type BillingPeriod,
  type VmStateTransitionEvent,
} from "./usageMath";
import {
  billingPeriodThrough,
  calculateActiveComputeHours,
  type BillingPeriod,
  type VmStateTransitionEvent,
} from "./usageMath";

export async function loadTeamVmStateTransitions(input: {
  readonly billingTeamId: string;
  readonly periodEnd: Date;
}): Promise<VmStateTransitionEvent[]> {
  const rows = await cloudDb()
    .select({
      id: cloudVmStateTransitions.id,
      vmId: cloudVmStateTransitions.vmId,
      billingTeamId: cloudVmStateTransitions.billingTeamId,
      fromState: cloudVmStateTransitions.fromState,
      toState: cloudVmStateTransitions.toState,
      createdAt: cloudVmStateTransitions.createdAt,
    })
    .from(cloudVmStateTransitions)
    .where(and(
      eq(cloudVmStateTransitions.billingTeamId, input.billingTeamId),
      lte(cloudVmStateTransitions.createdAt, input.periodEnd),
    ));
  return rows;
}

export async function getTeamActiveComputeHours(input: {
  readonly billingTeamId: string;
  readonly period: BillingPeriod;
}): Promise<number> {
  const events = await loadTeamVmStateTransitions({
    billingTeamId: input.billingTeamId,
    periodEnd: input.period.end,
  });
  return calculateActiveComputeHours(events, input.period);
}

/** Explicit name for API and job callers. */
export const getActiveComputeHoursForTeam = getTeamActiveComputeHours;

/**
 * Loads the VM events charged to one user-scoped plan. Personal Pro Stripe
 * rows use a Stack user id, while VM rows use the selected Stack team id, so
 * the subscription reporter must join through the owning VM instead of
 * assuming those identifiers are equal.
 */
export async function getUserPlanActiveComputeHours(input: {
  readonly userId: string;
  readonly billingPlanId: string;
  readonly period: BillingPeriod;
}): Promise<number> {
  const events = await cloudDb()
    .select({
      id: cloudVmStateTransitions.id,
      vmId: cloudVmStateTransitions.vmId,
      billingTeamId: cloudVmStateTransitions.billingTeamId,
      fromState: cloudVmStateTransitions.fromState,
      toState: cloudVmStateTransitions.toState,
      createdAt: cloudVmStateTransitions.createdAt,
    })
    .from(cloudVmStateTransitions)
    .innerJoin(cloudVms, eq(cloudVms.id, cloudVmStateTransitions.vmId))
    .where(and(
      eq(cloudVms.userId, input.userId),
      eq(cloudVms.billingPlanId, input.billingPlanId),
      lte(cloudVmStateTransitions.createdAt, input.period.end),
    ));
  return calculateActiveComputeHours(events, input.period);
}
