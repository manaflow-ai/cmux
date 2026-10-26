import { isAdminUser, type AdminAccessUser } from "../admin/access";

/**
 * cmux staff accounts are on the Team plan by default, with no Cloud machine
 * cap and no shared vCPU/memory pool. The gate is the admin gate: a
 * signed-in, non-anonymous user whose VERIFIED primary email is on a company
 * domain (cmux.com, manaflow.ai, manaflow.com). An unverified address never
 * qualifies, so a password sign-up cannot claim the grant.
 */
export function hasCompanyPlanGrant(user: AdminAccessUser | null | undefined): boolean {
  return isAdminUser(user);
}
