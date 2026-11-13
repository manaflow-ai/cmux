/**
 * The Freestyle metadata key the cmux vault reads before it puts an edge rule on a VM (cmux-vault
 * docs/integrations/cmux-cloud.md, Step 3): the vault acts on a VM only when the metadata under its caller's
 * `vmTenantMetadata` key equals the bare tenant. Each cmux Cloud environment is its own vault caller with its own
 * key, so a VM carries only the key of the platform environment that made it: cmux-platform development and staging
 * both create through cmux-vm-staging, and their service keys tell them apart.
 */
import type { Principal } from "../domain/principal.ts";

/** The vault callers' tenant rule (a Stack team id); any other tenant gets no key. */
const STACK_TEAM_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u;

export const VAULT_TENANT_KEYS = { development: "cmux_vt_dev", staging: "cmux_vt_stg", production: "cmux_vt" } as const;

/** The `[key, tenant]` to write on a VM this caller creates in `environment`, or null (local, preview, no team id). */
export const vaultTenantMetadata = (environment: string, caller: Principal): readonly [string, string] | null => {
  if (!STACK_TEAM_ID.test(caller.tenantId)) return null;
  if (environment === "production") return [VAULT_TENANT_KEYS.production, caller.tenantId];
  if (environment !== "staging") return null;
  const dev = caller.actor.kind === "service" && caller.actor.serviceId === "cloud-platform-dev";
  return [dev ? VAULT_TENANT_KEYS.development : VAULT_TENANT_KEYS.staging, caller.tenantId];
};
