/**
 * Trusted module: the only place a ServiceMayActFor proof is minted, and the
 * only way to build a service Principal (cx-b4h.13).
 *
 * A service key has no tenant. It acts for the team its request names, when
 * the key's team list allows that team. The Principal it gets carries the
 * key's scopes and labels: ownership proofs (tenant-owns-resource.ts) refuse
 * any resource without those labels, and create refuses a VM without them.
 */
import { defineProof, type Named, type Proof } from "@gdp-ts/core";
import type { ServiceKey } from "../auth/service-keys.ts";
import type { Principal } from "../domain/principal.ts";
import type { TenantId } from "../lib/ids.ts";

const ServiceMayActForProof = defineProof("ServiceMayActFor");

/** The service key `K` may act for the team `T`. */
export interface ServiceMayActFor<K, T> extends Proof<"ServiceMayActFor", [K, T]> {}

export const serviceMayActFor = <K, T>(key: Named<K, ServiceKey>, team: Named<T, TenantId>): ServiceMayActFor<K, T> | null =>
  key.value.teams === null || key.value.teams.has(team.value) ? ServiceMayActForProof.prove(key, team) : null;

/** The Principal of a service key acting for a team; it cannot be built without the proof. */
export const servicePrincipal = <K, T>(key: Named<K, ServiceKey>, team: Named<T, TenantId>, _proof: ServiceMayActFor<K, T>): Principal => ({
  tenantId: team.value,
  actor: { kind: "service", serviceId: key.value.id },
  scopes: key.value.scopes,
  resourceAllowlist: null,
  credentialExpiresAt: null,
  requiredLabels: key.value.labels,
});
