/**
 * Cleanup of TLS rules that no longer route anywhere the team may route:
 * rules naming a VM that was deleted (orphans), and rules left under a domain
 * the team released. Shared by the VM delete path (which the agent reaper
 * uses too) and the domain, rule and forward-auth handlers.
 *
 * Best effort and idempotent at the provider: a provider rule that is already
 * gone, or deleted now, is forgotten in cmux's table; one the provider fails
 * to delete keeps its row, so a later cleanup retries it. Orphans never hold
 * budget or block a release meanwhile (src/db/domains.ts counts live rules).
 */
import { name, type Named } from "@gdp-ts/core";
import { Effect, Option } from "effect";
import { DomainStore, type TlsRuleRow } from "../db/domains.ts";
import type { Principal } from "../domain/principal.ts";
import { TenantId } from "../lib/ids.ts";
import { tenantTlsRuleForCleanup } from "../proofs/domain-resource.ts";
import { UpstreamDomains } from "../upstream/domains.ts";

/** Deletes each of the caller's tenant's `rows` at the provider (best effort) and forgets the ones that are gone there. */
export const forgetTlsRules = <C>(caller: Named<C, Principal>, rows: ReadonlyArray<TlsRuleRow>) =>
  Effect.gen(function* () {
    const store = yield* DomainStore;
    const upstream = yield* UpstreamDomains;
    const tenantId = TenantId.make(caller.value.tenantId);
    for (const row of rows) {
      yield* name(row.id, (rule) => Effect.gen(function* () {
        const owned = yield* tenantTlsRuleForCleanup(caller, rule);
        if (owned === null) return;
        const deleted = yield* upstream.deleteTlsRule(owned.owns).pipe(Effect.option);
        if (Option.isSome(deleted)) yield* store.deleteTlsRule(tenantId, owned.row.id);
      }));
    }
  });

/** Forgets the tenant's rules orphaned by deleted VMs (only those naming `vmId`, when given). */
export const forgetOrphanedTlsRules = <C>(caller: Named<C, Principal>, vmId: string | null) =>
  Effect.gen(function* () {
    const orphans = yield* (yield* DomainStore).listOrphanedTlsRules(TenantId.make(caller.value.tenantId), vmId);
    yield* forgetTlsRules(caller, orphans);
  });
