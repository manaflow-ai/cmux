/**
 * Names of the resources this service creates upstream. The provider account
 * is shared with other cmux systems, so every name starts with
 * `cmux-vm-<environment> ` (for example `cmux-vm-staging team_x vm_...`):
 * a stray resource is attributable to this service, its environment and its
 * tenant, and other systems' resources never match this prefix.
 */
import type { Environment } from "../policy.ts";

export const upstreamNamePrefix = (environment: Environment): string => `cmux-vm-${environment} `;

/** The upstream display name of tenant `tenantId`'s resource `localId` (a cmux id). */
export const upstreamName = (environment: Environment, tenantId: string, localId: string): string =>
  `${upstreamNamePrefix(environment)}${tenantId} ${localId}`;
